package Plugins::LastFmGuidance::GraphJobs;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);
use JSON::PP qw(decode_json encode_json);
use Proc::Background;
use Plugins::LastFmGuidance::Provider;
use Plugins::LastFmGuidance::LibrarySnapshot;

my $process;
my $started_at = 0;
my $ended_at = 0;
my $last_error = '';
my $paused = 0;
my $operation = '';
my $graph_status_cache;

sub start_update {
    return { ok => 0, error => 'already_running' } if $process && $process->alive;
    return { ok => 0, error => 'library_scan_running' }
        if eval { require Slim::Music::Import; Slim::Music::Import->stillScanning };
    my $defaults = Plugins::LastFmGuidance::Provider::guidance_provider_defaults_v1();
    return { ok => 0, error => 'api_key_source_required' }
        unless ($defaults->{source} || '') eq 'api_key';
    my $provider_status = Plugins::LastFmGuidance::Provider::guidance_provider_status_v1();
    return { ok => 0, error => $provider_status->{reason} || 'provider_unavailable' }
        unless $provider_status->{available};
    my $api_key = Plugins::LastFmGuidance::Provider::_api_key();
    return { ok => 0, error => 'api_key_missing' } unless length $api_key;

    unlink Plugins::LastFmGuidance::Provider::_graph_cancel_path();
    unlink Plugins::LastFmGuidance::Provider::_graph_progress_path();
    unlink Plugins::LastFmGuidance::Provider::_graph_progress_path() . '.err';
    my $snapshot = eval {
        Plugins::LastFmGuidance::LibrarySnapshot::write_snapshot(
            Plugins::LastFmGuidance::Provider::_root_snapshot_path()
        );
    };
    if (!$snapshot) {
        $last_error = $@ || 'cannot_create_library_snapshot';
        return { ok => 0, error => $last_error };
    }
    my $request = {
        acquisition_mode => 'direct',
        store_path => Plugins::LastFmGuidance::Provider::_graph_store_path(),
        legacy_cache_path => Plugins::LastFmGuidance::Provider::_legacy_cache_path(),
        roots_path => Plugins::LastFmGuidance::Provider::_root_snapshot_path(),
        cancel_path => Plugins::LastFmGuidance::Provider::_graph_cancel_path(),
        retrieval_policy => $defaults->{retrieval_policy},
        storage_scope => $defaults->{storage_scope},
        artist_result_limit => 0 + $defaults->{artist_result_limit},
        budget_bytes => 0 + $defaults->{data_budget_mb} * 1_000_000,
    };
    _write_json(Plugins::LastFmGuidance::Provider::_graph_request_path(), $request);
    open my $progress, '>>', Plugins::LastFmGuidance::Provider::_graph_progress_path()
        or return { ok => 0, error => 'cannot_open_progress_file' };
    open my $errors, '>>', Plugins::LastFmGuidance::Provider::_graph_progress_path() . '.err'
        or return { ok => 0, error => 'cannot_open_error_file' };
    close $progress;
    close $errors;
    local $ENV{BLISS_GUIDANCE_LASTFM_API_KEY} = $api_key;
    $process = eval {
        _start_native_graph_process(
            Plugins::LastFmGuidance::Provider::_program_path(),
            'graph', 'sync', '--request', Plugins::LastFmGuidance::Provider::_graph_request_path(),
        );
    };
    unless ($process) {
        $last_error = 'cannot_start_native_graph_update';
        return { ok => 0, error => $last_error };
    }
    $started_at = time();
    $ended_at = 0;
    $last_error = '';
    $paused = 0;
    $operation = 'sync';
    Plugins::LastFmGuidance::Provider::_log_info(sprintf(
        'Offline Last.fm library update started: roots=%d, limit=%s, scope=%s, budget=%d MB',
        scalar(@{$snapshot->{artists} || []}),
        $defaults->{artist_result_limit} || 'unlimited',
        $defaults->{storage_scope},
        $defaults->{data_budget_mb},
    ));
    return { ok => 1, status => status() };
}

sub cancel {
    return { ok => 1, status => status() } unless $process && $process->alive;
    open my $fh, '>', Plugins::LastFmGuidance::Provider::_graph_cancel_path();
    print {$fh} time();
    close $fh;
    Plugins::LastFmGuidance::Provider::_log_info('Offline Last.fm library update cancellation requested')
        unless $paused;
    return { ok => 1, status => status() };
}

sub pause {
    $paused = 1;
    Plugins::LastFmGuidance::Provider::_log_info('Offline Last.fm library update pause requested');
    return cancel();
}

sub resume {
    return start_update();
}

sub start_compact {
    return { ok => 0, error => 'already_running' } if $process && $process->alive;
    my $defaults = Plugins::LastFmGuidance::Provider::guidance_provider_defaults_v1();
    return { ok => 0, error => 'api_key_source_required' }
        unless ($defaults->{source} || '') eq 'api_key';
    my $provider_status = Plugins::LastFmGuidance::Provider::guidance_provider_status_v1();
    return { ok => 0, error => $provider_status->{reason} || 'provider_unavailable' }
        unless $provider_status->{available};
    my $api_key = Plugins::LastFmGuidance::Provider::_api_key();
    return { ok => 0, error => 'api_key_missing' } unless length $api_key;
    unlink Plugins::LastFmGuidance::Provider::_graph_progress_path();
    unlink Plugins::LastFmGuidance::Provider::_graph_progress_path() . '.err';
    _write_json(Plugins::LastFmGuidance::Provider::_graph_request_path(), {
        acquisition_mode => 'direct',
        store_path => Plugins::LastFmGuidance::Provider::_graph_store_path(),
        legacy_cache_path => Plugins::LastFmGuidance::Provider::_legacy_cache_path(),
        storage_scope => $defaults->{storage_scope},
        artist_result_limit => 0 + $defaults->{artist_result_limit},
        budget_bytes => 0 + $defaults->{data_budget_mb} * 1_000_000,
    });
    open my $progress, '>>', Plugins::LastFmGuidance::Provider::_graph_progress_path()
        or return { ok => 0, error => 'cannot_open_progress_file' };
    open my $errors, '>>', Plugins::LastFmGuidance::Provider::_graph_progress_path() . '.err'
        or return { ok => 0, error => 'cannot_open_error_file' };
    close $progress;
    close $errors;
    local $ENV{BLISS_GUIDANCE_LASTFM_API_KEY} = $api_key;
    $process = eval {
        _start_native_graph_process(
            Plugins::LastFmGuidance::Provider::_program_path(),
            'graph', 'compact', '--request', Plugins::LastFmGuidance::Provider::_graph_request_path(),
        );
    };
    return { ok => 0, error => 'cannot_start_native_graph_compaction' } unless $process;
    $started_at = time();
    $ended_at = 0;
    $last_error = '';
    $paused = 0;
    $operation = 'compact';
    Plugins::LastFmGuidance::Provider::_log_info('Offline Last.fm graph compaction started');
    return { ok => 1, status => status() };
}

sub delete_graph {
    return { ok => 0, error => 'already_running' } if $process && $process->alive;
    my $defaults = Plugins::LastFmGuidance::Provider::guidance_provider_defaults_v1();
    return { ok => 0, error => 'api_key_source_required' }
        unless ($defaults->{source} || '') eq 'api_key';
    my $provider_status = Plugins::LastFmGuidance::Provider::guidance_provider_status_v1();
    return { ok => 0, error => $provider_status->{reason} || 'provider_unavailable' }
        unless $provider_status->{available};
    my $request_path = Plugins::LastFmGuidance::Provider::_graph_request_path() . '.delete';
    _write_json($request_path, {
        store_path => Plugins::LastFmGuidance::Provider::_graph_store_path(),
        legacy_cache_path => Plugins::LastFmGuidance::Provider::_legacy_cache_path(),
        confirmed => JSON::PP::true,
    });
    my $exit = system(
        Plugins::LastFmGuidance::Provider::_program_path(),
        'graph', 'delete', '--request', $request_path,
    );
    unlink $request_path;
    return { ok => 0, error => 'native_graph_delete_failed' } if $exit != 0;
    unlink Plugins::LastFmGuidance::Provider::_graph_progress_path();
    unlink Plugins::LastFmGuidance::Provider::_graph_progress_path() . '.err';
    unlink Plugins::LastFmGuidance::Provider::_graph_cancel_path();
    $started_at = 0;
    $ended_at = 0;
    $last_error = '';
    $paused = 0;
    $operation = '';
    Plugins::LastFmGuidance::Provider::_log_info('Offline Last.fm data deleted');
    return { ok => 1, status => status(), graph => graph_status() };
}

sub status {
    my $running = $process && $process->alive ? 1 : 0;
    my $event = _last_progress_event();
    if (($event->{state} || '') eq 'compacted') {
        $event->{message} = 'Offline Last.fm data compacted';
        $event->{finished} = 1;
    }
    if (!$running && $process) {
        my $exit = eval { $process->wait };
        $ended_at ||= time();
        $paused = 1 if $event->{paused};
        my $structured_error = (($event->{state} || '') eq 'failed' || $event->{error})
            ? ($event->{error} || 'native_graph_update_failed')
            : '';
        if (length $structured_error && !$event->{cancelled}) {
            $last_error = $structured_error;
            Plugins::LastFmGuidance::Provider::_log_error(
                'Offline Last.fm library update failed: ' . $last_error
            );
        }
        elsif (defined $exit && $exit != 0 && !$event->{cancelled}) {
            $last_error = _last_error_line() || 'native_graph_update_failed';
            Plugins::LastFmGuidance::Provider::_log_error(
                'Offline Last.fm library update failed: ' . $last_error
            );
        }
        elsif ($event->{paused}) {
            Plugins::LastFmGuidance::Provider::_log_warning(
                'Offline Last.fm library update paused by the native provider: '
                    . ($event->{message} || 'temporary failure')
            );
        }
        elsif ($event->{cancelled}) {
            Plugins::LastFmGuidance::Provider::_log_info(
                $paused ? 'Offline Last.fm library update paused' : 'Offline Last.fm library update cancelled'
            );
        }
        elsif ($event->{finished}) {
            Plugins::LastFmGuidance::Provider::_log_info(sprintf(
                'Offline Last.fm library update completed: roots=%d, requests=%d, cached=%d, changed=%d',
                $event->{total} || 0,
                $event->{requests} || 0,
                $event->{cached} || 0,
                $event->{changed} || 0,
            ));
        }
        undef $process;
        graph_status();
    }
    return {
        running => $running,
        paused => $paused ? 1 : 0,
        started_at => 0 + $started_at,
        duration => $started_at ? (($running ? time() : ($ended_at || time())) - $started_at) : 0,
        error => $last_error,
        operation => $operation,
        progress => $event,
    };
}

sub perform_action {
    my ($action) = @_;
    return start_update() if $action eq 'start';
    return cancel() if $action eq 'cancel';
    return pause() if $action eq 'pause';
    return resume() if $action eq 'resume';
    return start_compact() if $action eq 'compact';
    return delete_graph() if $action eq 'delete';
    return { ok => 1, status => status(), graph => $graph_status_cache || {} }
        if $action eq 'status';
    return { ok => 0, error => 'bad_action', status => status() };
}

sub graph_status {
    $graph_status_cache = _read_graph_status();
    return $graph_status_cache;
}

sub _read_graph_status {
    my $defaults = Plugins::LastFmGuidance::Provider::guidance_provider_defaults_v1();
    return { state => 'unavailable' }
        unless ($defaults->{source} || '') eq 'api_key';
    my $provider_status = Plugins::LastFmGuidance::Provider::guidance_provider_status_v1();
    return { state => 'unavailable' } unless $provider_status->{available};
    my $request_path = Plugins::LastFmGuidance::Provider::_graph_request_path() . '.status';
    _write_json($request_path, {
        store_path => Plugins::LastFmGuidance::Provider::_graph_store_path(),
        legacy_cache_path => Plugins::LastFmGuidance::Provider::_legacy_cache_path(),
    });
    my $program = Plugins::LastFmGuidance::Provider::_program_path();
    my $output = eval { qx("$program" graph status --request "$request_path") } || '';
    unlink $request_path;
    return eval { decode_json($output) } || { state => 'unavailable' };
}

sub _last_progress_event {
    my $path = Plugins::LastFmGuidance::Provider::_graph_progress_path();
    return {} unless -r $path;
    open my $fh, '<', $path or return {};
    my $last = '';
    while (my $line = <$fh>) {
        $last = $line if $line =~ /\S/;
    }
    close $fh;
    return eval { decode_json($last) } || {};
}

sub _last_error_line {
    my $path = Plugins::LastFmGuidance::Provider::_graph_progress_path() . '.err';
    return '' unless -r $path;
    open my $fh, '<', $path or return '';
    my $last = '';
    while (my $line = <$fh>) {
        chomp $line;
        $last = $line if $line =~ /\S/;
    }
    close $fh;
    return $last;
}

sub _write_json {
    my ($path, $value) = @_;
    my $temporary = $path . '.tmp';
    open my $fh, '>', $temporary or die "Cannot write Last.fm graph request: $!";
    print {$fh} encode_json($value);
    close $fh or die "Cannot finish Last.fm graph request: $!";
    rename $temporary, $path or die "Cannot publish Last.fm graph request: $!";
}

sub _start_native_graph_process {
    my @command = @_;
    return Proc::Background->new(
        { die_upon_destroy => 1 },
        $^X,
        catfile(dirname(__FILE__), 'GraphRunner.pl'),
        Plugins::LastFmGuidance::Provider::_graph_progress_path(),
        Plugins::LastFmGuidance::Provider::_graph_progress_path() . '.err',
        @command,
    );
}

1;
