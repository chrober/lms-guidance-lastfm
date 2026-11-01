package Plugins::LastFmGuidance::Plugin;

use strict;
use base qw(Slim::Plugin::Base);
use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);
use Plugins::LastFmGuidance::Provider;
use Plugins::LastFmGuidance::PersistenceLog;
use IO::Socket::INET;
use Slim::Networking::Select;

my ($persistence_socket, $persistence_port_file, $persistence_port);

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
}

sub shutdownPlugin {
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
