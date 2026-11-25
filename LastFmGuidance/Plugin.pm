package Plugins::LastFmGuidance::Plugin;

use strict;
use base qw(Slim::Plugin::Base);
use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);
use File::Spec ();
use JSON::PP qw(encode_json);
use Plugins::LastFmGuidance::Provider;
use Plugins::LastFmGuidance::PersistenceLog;
use IO::Socket::INET;
use Slim::Networking::Select;

my ($persistence_socket, $persistence_port_file, $persistence_port, $deferred_runtime, $drain_request_path, $scan_start_listener);
my $drain_serial = 0;

sub getDisplayName { return 'PLUGIN_LASTFMGUIDANCE_NAME'; }

sub initPlugin {
    my $class = shift;
    Plugins::LastFmGuidance::Provider::init_preferences();
    Plugins::LastFmGuidance::Provider::init_logging();
    _start_persistence_notifications();
    _drain_persistence_reports();
    _load_strings();
    if (main::WEBUI) {
        require 'Plugins/LastFmGuidance/Settings.pm';
        Plugins::LastFmGuidance::Settings->new;
    }
    require Slim::Control::Request;
    _start_deferred_persistence();
    Slim::Control::Request::addDispatch(
        ['lastfmguidance', 'graph', '_action'],
        [0, 0, 1, \&_graphCommand],
    );
    $class->SUPER::initPlugin();
}

sub _drain_persistence_reports {
    my $dir = catfile(Plugins::LastFmGuidance::Provider::_cache_root(), 'persistence-errors');
    Plugins::LastFmGuidance::PersistenceLog::drain($dir, sub {
        Plugins::LastFmGuidance::Provider::_log_warning($_[0]);
    }, sub {
        Plugins::LastFmGuidance::Provider::_log_info($_[0]);
    });
}

sub _start_persistence_notifications {
    return if $persistence_socket;
    my $socket = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'udp');
    unless ($socket) {
        Plugins::LastFmGuidance::Provider::_log_warning('Last.fm persistence notification listener unavailable; pending reports will be recovered on restart');
        return;
    }
    $socket->blocking(0);
    my $path = catfile(Plugins::LastFmGuidance::Provider::_cache_root(), 'persistence-notify-port');
    my $out;
    if (-l $path || !open($out, '>', $path)) {
        close $socket;
        Plugins::LastFmGuidance::Provider::_log_warning('Last.fm persistence notification endpoint unavailable; pending reports will be recovered on restart');
        return;
    }
    my $port = $socket->sockport;
    my $written = print {$out} "$port\n";
    my $closed = close $out;
    unless ($written && $closed) {
        unlink $path;
        close $socket;
        Plugins::LastFmGuidance::Provider::_log_warning('Last.fm persistence notification endpoint unavailable; pending reports will be recovered on restart');
        return;
    }
    ($persistence_socket, $persistence_port_file, $persistence_port) = ($socket, $path, $port);
    Slim::Networking::Select::addRead($socket, \&_persistence_notification);
}

sub _persistence_notification {
    my $socket = shift;
    return unless defined $socket->recv(my $message, 32);
    _drain_persistence_reports();
    $deferred_runtime->trigger if $deferred_runtime;
}

sub _start_deferred_persistence {
    require Plugins::LastFmGuidance::DeferredPersistence;
    require Slim::Utils::Timers;
    $deferred_runtime = Plugins::LastFmGuidance::DeferredPersistence->new(
        is_scanning => sub {
            my $scanning = eval { require Slim::Music::Import; Slim::Music::Import->stillScanning };
            return $@ ? 1 : ($scanning ? 1 : 0);
        },
        has_pending => sub { _has_pending_deferred() },
        launch => sub { _launch_deferred_persistence() },
        subscribe => sub { Slim::Control::Request::subscribe($_[0], [['rescan'], ['done']]) },
        unsubscribe => sub { Slim::Control::Request::unsubscribe($_[0]) },
        schedule => sub { Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 1, $_[0]) },
        cleanup => sub { unlink $drain_request_path if $drain_request_path && !-l $drain_request_path && -f $drain_request_path; undef $drain_request_path },
        on_error => sub { Plugins::LastFmGuidance::Provider::_log_warning('Last.fm deferred persistence: ' . $_[0]) },
    );
    $deferred_runtime->start;
    $scan_start_listener = sub {
        my $request = shift;
        return unless $request && $request->isCommand([['rescan']]);
        return if $request->isCommand([['rescan'], ['done']]);
        $deferred_runtime->scan_started if $deferred_runtime;
    };
    Slim::Control::Request::subscribe($scan_start_listener, [['rescan']]);
}

sub _has_pending_deferred {
    my $dir = Plugins::LastFmGuidance::Provider::_graph_store_path();
    $dir .= '.pending-artist-writes';
    return 0 unless -d $dir && !-l $dir && opendir(my $dh, $dir);
    my $found = scalar grep { /\A[0-9a-f]{64}\.(?:json|tmp-\d+)\z/ } readdir($dh);
    closedir($dh);
    return $found;
}

sub _launch_deferred_persistence {
    require Proc::Background;
    require Time::HiRes;
    my $defaults = Plugins::LastFmGuidance::Provider::guidance_provider_defaults_v1();
    my $library = Plugins::LastFmGuidance::Provider::_library_db_path();
    die 'Lyrion library database is unavailable' if ($defaults->{storage_scope} || '') eq 'local_artists_only' && !length($library);
    my $program = Plugins::LastFmGuidance::Provider::_program_path();
    die 'native Last.fm provider is unavailable' unless -f $program;
    my $request = {
        acquisition_mode => 'direct',
        store_path => Plugins::LastFmGuidance::Provider::_graph_store_path(),
        legacy_cache_path => Plugins::LastFmGuidance::Provider::_legacy_cache_path(),
        storage_scope => $defaults->{storage_scope},
        artist_result_limit => 0 + $defaults->{artist_result_limit},
        budget_bytes => 0 + $defaults->{data_budget_mb} * 1_000_000,
        request_deadline_ms => 5000, max_concurrent_requests => 2,
    };
    $request->{library_db_path} = $library if length $library;
    my $path = catfile(Plugins::LastFmGuidance::Provider::_cache_root(), 'deferred-drain-' . $$ . '-' . ++$drain_serial . '.json');
    open my $fh, '>:raw', $path or die "cannot write deferred drain request: $!";
    print {$fh} encode_json($request) or die "cannot write deferred drain request: $!";
    close $fh or die "cannot close deferred drain request: $!";
    $drain_request_path = $path;
    local $ENV{BLISS_GUIDANCE_LASTFM_API_KEY};
    delete $ENV{BLISS_GUIDANCE_LASTFM_API_KEY};
    return Proc::Background->new({die_upon_destroy => 1}, $^X,
        catfile(dirname(__FILE__), 'GraphRunner.pl'), File::Spec->devnull(), File::Spec->devnull(),
        $program, 'drain-guidance-background', $path);
}

sub shutdownPlugin {
    $deferred_runtime->stop if $deferred_runtime;
    undef $deferred_runtime;
    Slim::Control::Request::unsubscribe($scan_start_listener) if $scan_start_listener;
    undef $scan_start_listener;
    if ($persistence_socket) {
        Slim::Networking::Select::removeRead($persistence_socket);
        close $persistence_socket;
        undef $persistence_socket;
    }
    if ($persistence_port_file && !-l $persistence_port_file && open(my $in, '<', $persistence_port_file)) {
        my $port = <$in>;
        close $in;
        unlink $persistence_port_file if defined $port && $port =~ /^\Q$persistence_port\E\s*$/;
    }
    undef $persistence_port_file;
    undef $persistence_port;
}

sub _graphCommand {
    my $request = shift;
    if ($request->isNotCommand([['lastfmguidance'], ['graph']])) {
        $request->setStatusBadDispatch();
        return;
    }
    my $action = $request->getParam('_action') || '';
    unless ($action =~ /^(?:status|start|pause|resume|cancel|compact|delete)$/) {
        $request->setStatusBadParams();
        return;
    }
    require Plugins::LastFmGuidance::GraphJobs;
    my $result = Plugins::LastFmGuidance::GraphJobs::perform_action($action);
    my $status = $result->{status} || Plugins::LastFmGuidance::GraphJobs::status();
    my $progress = $status->{progress} || {};
    my $graph = $result->{graph} || {};
    my $defaults = Plugins::LastFmGuidance::Provider::guidance_provider_defaults_v1();
    my $budget_bytes = 0 + ($defaults->{data_budget_mb} || 100) * 1_000_000;
    my $rejected_at = Plugins::LastFmGuidance::PersistenceLog::last_budget_rejection(catfile(Plugins::LastFmGuidance::Provider::_cache_root(), 'persistence-errors'));
    for my $pair (
        [ok => $result->{ok} ? 1 : 0],
        [error => $result->{error} || $status->{error} || ''],
        [running => $status->{running} || 0],
        [paused => $status->{paused} || 0],
        [start => $status->{started_at} || 0],
        [duration => $status->{duration} || 0],
        [message => $progress->{message} || ''],
        [current_artist => $progress->{current_artist} || ''],
        [current => $progress->{current} || 0],
        [total => $progress->{total} || 0],
        [requests => $progress->{requests} || 0],
        [cached => $progress->{cached} || 0],
        [changed => $progress->{changed} || 0],
        [finished => $progress->{finished} ? 1 : 0],
        [cancelled => $progress->{cancelled} ? 1 : 0],
        [retry_at => $progress->{retry_at} || 0],
        [budget_exhausted => $progress->{budget_exhausted} ? 1 : 0],
        [graph_budget_bytes => $budget_bytes],
        [graph_budget_rejected_at => $rejected_at],
        [retained_lastfm_bytes => $progress->{retained_lastfm_bytes} || $graph->{retained_lastfm_bytes} || 0],
        [operation => $status->{operation} || ''],
        [cleanup_done => ($progress->{state} || '') eq 'compacted' ? 1 : 0],
        [repaired_names => $progress->{repaired_names} || 0],
        [removed_orphans => $progress->{removed_orphans} || 0],
        [ambiguous_names => $progress->{ambiguous_names} || 0],
        [graph_state => $graph->{state} || ''],
        [graph_artists => $graph->{artists} || 0],
        [graph_observations => $graph->{artist_observations} || 0],
        [graph_bytes => $graph->{database_bytes} || $progress->{database_bytes} || 0],
        [graph_database_bytes => $graph->{database_bytes} || $progress->{database_bytes} || 0],
        [graph_retained_lastfm_bytes => $graph->{retained_lastfm_bytes} || $progress->{retained_lastfm_bytes} || 0],
        [graph_library_artists => $graph->{library_artists} || 0],
        [graph_covered_artists => $graph->{covered_library_artists} || 0],
        [graph_external_artists => $graph->{external_artists} || 0],
        [graph_artist_edges => $graph->{artist_edges} || 0],
        [graph_reciprocal_pairs => $graph->{reciprocal_artist_pairs} || 0],
    ) {
        $request->addResult($pair->[0], $pair->[1]);
    }
    $request->setStatusDone();
}

sub _load_strings {
    my $path = catfile(dirname(__FILE__), 'strings.txt');
    return unless -r $path;
    eval {
        require Slim::Utils::Strings;
        Slim::Utils::Strings::loadFile($path);
    };
}

sub guidance_provider_descriptor_v1 { return Plugins::LastFmGuidance::Provider::guidance_provider_descriptor_v1(); }
sub guidance_provider_defaults_v1 { return Plugins::LastFmGuidance::Provider::guidance_provider_defaults_v1(); }
sub guidance_provider_status_v1 { return Plugins::LastFmGuidance::Provider::guidance_provider_status_v1(); }
sub guidance_provider_native_spi_config_v1 { shift; return Plugins::LastFmGuidance::Provider::guidance_provider_native_spi_config_v1(@_); }
sub guidance_provider_process_environment_v1 { shift; return Plugins::LastFmGuidance::Provider::guidance_provider_process_environment_v1(@_); }
sub guidance_provider_acquire_artifacts_v1 { shift; return Plugins::LastFmGuidance::Provider::guidance_provider_acquire_artifacts_v1(@_); }
sub guidance_provider_log_events_v1 { shift; return Plugins::LastFmGuidance::Provider::guidance_provider_log_events_v1(@_); }
sub graph_job_status { require Plugins::LastFmGuidance::GraphJobs; return Plugins::LastFmGuidance::GraphJobs::status(); }
sub start_graph_update { require Plugins::LastFmGuidance::GraphJobs; return Plugins::LastFmGuidance::GraphJobs::start_update(); }
sub cancel_graph_update { require Plugins::LastFmGuidance::GraphJobs; return Plugins::LastFmGuidance::GraphJobs::cancel(); }
sub pause_graph_update { require Plugins::LastFmGuidance::GraphJobs; return Plugins::LastFmGuidance::GraphJobs::pause(); }
sub resume_graph_update { require Plugins::LastFmGuidance::GraphJobs; return Plugins::LastFmGuidance::GraphJobs::resume(); }

1;
