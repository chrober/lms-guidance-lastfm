package Plugins::LastFmGuidance::Provider;

use strict;
use warnings;
use Config qw(%Config);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec::Functions qw(catfile);
use File::Spec ();
use JSON::PP qw(decode_json encode_json);
use POSIX qw(strftime);
use Slim::Utils::Prefs;

my $prefs = Slim::Utils::Prefs::preferences('plugin.guidancelastfm');
my $serverprefs = Slim::Utils::Prefs::preferences('server');
my $log;

my %FACTORY_DEFAULTS = (
    source                   => 'lastmix',
    api_key                  => '',
    lastfm_track_influence   => 25,
    lastfm_artist_mode       => 'target_share',
    lastfm_artist_level      => 75,
    retrieval_policy        => 'online_with_cache',
    storage_scope           => 'all_returned_artists',
    artist_result_limit     => 25,
    data_budget_mb          => 100,
    artist_refresh_days     => 0,
    empty_artist_refresh_days => 0,
    settings_revision        => 1,
);

my %RANGES = (
    lastfm_track_influence => [0, 100],
    lastfm_artist_level    => [0, 100],
);

sub init_preferences {
    $prefs->init({ %FACTORY_DEFAULTS });
}

sub init_logging {
    return $log if $log;
    return unless eval { require Slim::Utils::Log; 1 };
    $log = Slim::Utils::Log->addLogCategory({
        category => 'plugin.guidancelastfm',
        defaultLevel => 'WARN',
        description => 'PLUGIN_LASTFMGUIDANCE_NAME',
    });
    return $log;
}

sub guidance_provider_descriptor_v1 {
    return {
        protocol_version => 1,
        provider_id => 'lastfm',
        display_name => 'Bliss Guidance: Last.fm',
        settings_uri => 'plugins/LastFmGuidance/settings/lastfmguidance.html',
        capabilities => [qw(lastfm_similarity lastfm_acquisition)],
        scopes => [qw(global_candidate edge_candidate)],
        settings_schema_version => 1,
        controls => [
            {
                key => 'source', type => 'enum', values => [qw(lastmix api_key)],
                option_labels => {
                    lastmix => 'GUIDANCE_LASTFM_SOURCE_LASTMIX',
                    api_key => 'GUIDANCE_LASTFM_SOURCE_API_KEY',
                },
                factory_default => 'lastmix', host_overridable => 1,
                label_token => 'GUIDANCE_LASTFM_SOURCE',
                help_token => 'GUIDANCE_LASTFM_SOURCE_DESC',
            },
            {
                key => 'lastfm_track_influence', type => 'integer', minimum => 0,
                maximum => 100, factory_default => 25, host_overridable => 1,
                guidance_channel => 'lastfm_track', render_as => 'slider',
                label_token => 'GUIDANCE_LASTFM_TRACK_INFLUENCE',
                help_token => 'GUIDANCE_LASTFM_TRACK_INFLUENCE_DESC',
            },
            {
                key => 'lastfm_artist_mode', type => 'enum',
                values => [qw(target_share bounded_influence)],
                option_labels => {
                    target_share => 'GUIDANCE_LASTFM_ARTIST_MODE_TARGET_SHARE',
                    bounded_influence => 'GUIDANCE_LASTFM_ARTIST_MODE_BOUNDED',
                },
                factory_default => 'target_share', host_overridable => 1,
                label_token => 'GUIDANCE_LASTFM_ARTIST_MODE',
                help_token => 'GUIDANCE_LASTFM_ARTIST_MODE_DESC',
            },
            {
                key => 'lastfm_artist_level', type => 'integer', minimum => 0,
                maximum => 100, factory_default => 75, host_overridable => 1,
                guidance_channel => 'lastfm_artist', render_as => 'slider',
                guidance_policy => 'target_share_or_bounded',
                guidance_mode_key => 'lastfm_artist_mode',
                label_token => 'GUIDANCE_LASTFM_ARTIST_LEVEL',
                help_token => 'GUIDANCE_LASTFM_ARTIST_LEVEL_DESC',
            },
        ],
        native_spi => {
            provider_id => 'lastfm-guidance',
            spi_version => 2,
            protocol => 'bliss-guidance-jsonl-v2',
            channels => {
                similar_track => 'lastfm_track',
                similar_artist => 'lastfm_artist',
            },
            artifact_kinds => ['resolved-lastfm-evidence-v1'],
            resource_kinds => [],
        },
    };
}

sub guidance_provider_defaults_v1 {
    init_preferences();
    my %defaults;
    $defaults{source} = _source($prefs->get('source'));
    $defaults{lastfm_artist_mode} = _artist_mode($prefs->get('lastfm_artist_mode'));
    for my $key (keys %RANGES) {
        my ($minimum, $maximum) = @{$RANGES{$key}};
        my $value = $prefs->get($key);
        $value = $FACTORY_DEFAULTS{$key} unless defined $value && $value =~ /^\d+$/;
        $value = int($value);
        $value = $minimum if $value < $minimum;
        $value = $maximum if $value > $maximum;
        $defaults{$key} = $value;
    }
    $defaults{settings_revision} = int($prefs->get('settings_revision') || $FACTORY_DEFAULTS{settings_revision});
    $defaults{retrieval_policy} = _retrieval_policy($prefs->get('retrieval_policy'));
    $defaults{storage_scope} = _storage_scope($prefs->get('storage_scope'));
    my $artist_result_limit = $prefs->get('artist_result_limit');
    $defaults{artist_result_limit} = defined($artist_result_limit) && $artist_result_limit =~ /^\d+$/
        ? int($artist_result_limit) : 25;
    my $data_budget_mb = $prefs->get('data_budget_mb');
    $data_budget_mb = 100 unless defined($data_budget_mb) && $data_budget_mb =~ /^\d+$/;
    $data_budget_mb = 1 if $data_budget_mb < 1;
    $defaults{data_budget_mb} = int($data_budget_mb);
    for my $key (qw(artist_refresh_days empty_artist_refresh_days)) {
        my $value = $prefs->get($key);
        $defaults{$key} = defined($value) && $value =~ /^\d+$/ && $value <= 4294967295 ? int($value) : 0;
    }
    return \%defaults;
}

sub guidance_provider_status_v1 {
    my $defaults = guidance_provider_defaults_v1();
    return _provider_status_for_source($defaults->{source});
}

sub _provider_status_for_source {
    my ($source) = @_;
    my $program = _program_path();
    return { available => 0, reason => 'native_binary_missing', program => '' }
        unless -f $program && (-x $program || $^O =~ /^(?:MSWin32|msys)$/);

    my $version = _binary_version($program);
    return { available => 0, reason => 'native_binary_incompatible', program => $program }
        unless _binary_metadata_compatible($version);

    if (($source || '') eq 'lastmix') {
        return { available => 0, reason => 'lastmix_unavailable', program => $program }
            unless _lastmix_available();
    }
    else {
        return { available => 0, reason => 'native_binary_incompatible', program => $program }
            unless _binary_graph_compatible($version);
        my $defaults = guidance_provider_defaults_v1();
        if ($defaults->{artist_refresh_days} || $defaults->{empty_artist_refresh_days}) {
            my $metadata = eval { decode_json($version || '') };
            return { available => 0, reason => 'native_binary_incompatible', program => $program }
                unless ref($metadata) eq 'HASH' && $metadata->{artist_refresh_targets};
        }
        return { available => 0, reason => 'api_key_missing', program => $program }
            unless _api_key();
    }

    return { available => 1, reason => '', program => $program, version => $version };
}

sub _binary_graph_compatible {
    my ($version) = @_;
    my $metadata = eval { decode_json($version || '') };
    return 0 unless ref($metadata) eq 'HASH';
    return 0 unless ($metadata->{offline_graph_schema_version} || 0) == 2;
    my %commands = map { $_ => 1 }
        grep { defined $_ && !ref($_) }
        @{ref($metadata->{graph_commands}) eq 'ARRAY' ? $metadata->{graph_commands} : []};
    return $commands{status} && $commands{sync} && $commands{compact} && $commands{delete} ? 1 : 0;
}

sub _binary_metadata_compatible {
    my ($version) = @_;
    my $metadata = eval { decode_json($version || '') };
    return 0 unless ref($metadata) eq 'HASH';
    return 0 unless ($metadata->{provider_id} || '') eq 'lastfm-guidance';
    return 0 unless ($metadata->{spi_version} || 0) == 2;

    my %acquisition = map { $_ => 1 }
        grep { defined $_ && !ref($_) }
        @{ref($metadata->{acquisition_modes}) eq 'ARRAY' ? $metadata->{acquisition_modes} : []};
    return 0 unless $acquisition{artifact} && $acquisition{direct};

    my $policies = $metadata->{channel_policies};
    return 0 unless ref($policies) eq 'HASH';
    my %track_policies = map { $_ => 1 }
        grep { defined $_ && !ref($_) }
        @{ref($policies->{lastfm_track}) eq 'ARRAY' ? $policies->{lastfm_track} : []};
    my %artist_policies = map { $_ => 1 }
        grep { defined $_ && !ref($_) }
        @{ref($policies->{lastfm_artist}) eq 'ARRAY' ? $policies->{lastfm_artist} : []};
    return 0 unless $track_policies{bounded_influence};
    return 0 unless $artist_policies{bounded_influence} && $artist_policies{target_share};
    return 1;
}

sub guidance_provider_process_environment_v1 {
    my ($resolved_policy, $trusted_context) = @_;
    my $defaults = guidance_provider_defaults_v1();
    my $effective = _effective_policy($resolved_policy || {}, $defaults);
    return {} unless $effective->{source} eq 'api_key';
    my $api_key = _api_key();
    return {} unless length $api_key;
    return { BLISS_GUIDANCE_LASTFM_API_KEY => $api_key };
}

sub guidance_provider_native_spi_config_v1 {
    my ($resolved_policy, $trusted_context) = @_;
    $trusted_context ||= {};
    my $defaults = guidance_provider_defaults_v1();
    my $effective = _effective_policy($resolved_policy || {}, $defaults);
    my $status = _provider_status_for_source($effective->{source});
    die 'Last.fm guidance provider is unavailable: ' . ($status->{reason} || 'unknown')
        unless $status->{available};

    my @artifacts;
    my $options = {
        acquisition_mode => $effective->{source} eq 'api_key' ? 'direct' : 'artifact',
        lastfm_track_influence => $effective->{lastfm_track_influence},
        lastfm_artist_mode => $effective->{lastfm_artist_mode},
        lastfm_artist_level => $effective->{lastfm_artist_level},
        diagnostic_level => _diagnostic_level(),
    };
    if ($effective->{source} eq 'lastmix') {
        my $artifact = $trusted_context->{lastfm_relations_artifact};
        die 'Last.fm LastMix mode requires a trusted resolved evidence artifact'
            unless ref($artifact) eq 'HASH' && $artifact->{path} && $artifact->{sha256}
                && ($artifact->{kind} || '') eq 'resolved-lastfm-evidence-v1';
        push @artifacts, {
            kind => 'resolved-lastfm-evidence-v1', path => $artifact->{path}, sha256 => $artifact->{sha256},
        };
    }
    else {
        $options->{store_path} = _graph_store_path();
        $options->{legacy_cache_path} = _legacy_cache_path();
        $options->{retrieval_policy} = $defaults->{retrieval_policy};
        $options->{storage_scope} = $defaults->{storage_scope};
        $options->{artist_result_limit} = 0 + $defaults->{artist_result_limit};
        $options->{budget_bytes} = 0 + $defaults->{data_budget_mb} * 1_000_000;
        for my $key (qw(artist_refresh_days empty_artist_refresh_days)) {
            $options->{$key} = 0 + $defaults->{$key} if $defaults->{$key};
        }
        $options->{request_deadline_ms} = 5000;
        $options->{max_concurrent_requests} = 2;
        if (defined $trusted_context->{api_endpoint} && length $trusted_context->{api_endpoint}) {
            $options->{api_endpoint} = $trusted_context->{api_endpoint};
        }
    }

    return {
        id => 'lastfm-guidance',
        program => $status->{program},
        options => $options,
        artifacts => \@artifacts,
        resources => [],
        timeout_ms => 5000,
    };
}

sub guidance_provider_acquire_artifacts_v1 {
    my ($resolved_policy, $trusted_context, $on_complete) = @_;
    my $effective = _effective_policy($resolved_policy || {}, guidance_provider_defaults_v1());
    return $on_complete->({ available => 1, artifacts => [], diagnostic => '' })
        if $effective->{source} eq 'api_key';
    return $on_complete->({ available => 0, artifacts => [], diagnostic => 'LastMix is not installed' })
        unless _lastmix_available();

    $trusted_context ||= {};
    my $path = $trusted_context->{artifact_path} || '';
    my $sources = $trusted_context->{source_tracks};
    return $on_complete->({ available => 0, artifacts => [], diagnostic => 'trusted LastMix artifact path is missing' })
        unless length $path;
    return $on_complete->({ available => 0, artifacts => [], diagnostic => 'trusted LastMix source tracks are missing' })
        unless ref($sources) eq 'ARRAY';
    return $on_complete->({ available => 0, artifacts => [], diagnostic => 'LastMix API is unavailable' })
        unless eval { require Plugins::LastMix::LFM; 1 };

    my (@requests, %seen_track, %seen_artist);
    for my $track (@$sources) {
        next unless ref($track) eq 'HASH';
        my $artist = $track->{artist} || '';
        my $title = $track->{title} || '';
        my $track_key = _normalize($artist) . '|' . _normalize($title);
        if (length $artist && length $title && !$seen_track{$track_key}++) {
            push @requests, { kind => 'track', %$track };
        }
        my $artist_key = _normalize($artist);
        if (length $artist_key && !$seen_artist{$artist_key}++) {
            push @requests, {
                kind => 'artist', artist => $artist,
                artist_mbid => ref($track->{artist_mbids}) eq 'ARRAY' ? $track->{artist_mbids}[0] : undef,
            };
        }
    }

    my @edges;
    my @errors;
    my $requests = 0;
    my $failures = 0;
    my $next;
    $next = sub {
        unless (@requests) {
            my $state = $failures ? (@edges ? 'partial' : 'failed') : 'fresh';
            my $bundle = {
                schema_version => 1,
                frozen_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time())),
                providers => [{
                    provider => 'last.fm',
                    dataset_or_algorithm => 'LastMix track.getSimilar + artist.getSimilar',
                    state => $state,
                    request_count => 0 + $requests,
                    failure_count => 0 + $failures,
                    error_codes => \@errors,
                }],
                edges => \@edges,
            };
            _log_info(sprintf(
                'Last.fm guidance prepared: requests=%d, cache hits=0, failures=%d, track relations=%d, artist relations=%d',
                $requests,
                $failures,
                scalar(grep { ($_->{source}{kind} || '') eq 'recording' } @edges),
                scalar(grep { ($_->{source}{kind} || '') eq 'artist' } @edges),
            ));
            my $candidate_tracks = $trusted_context->{candidate_tracks};
            if (ref($candidate_tracks) eq 'ARRAY') {
                $bundle->{edges} = _resolve_candidate_edges(
                    $bundle->{edges}, $candidate_tracks,
                );
            }
            my $fh;
            unless (open $fh, '>', $path) {
                return $on_complete->({ available => 0, artifacts => [], diagnostic => 'cannot write trusted LastMix artifact' });
            }
            print {$fh} encode_json($bundle);
            close $fh;
            open my $read_fh, '<', $path or return $on_complete->({ available => 0, artifacts => [], diagnostic => 'cannot verify trusted LastMix artifact' });
            binmode $read_fh;
            local $/;
            my $sha256 = sha256_hex(<$read_fh>);
            close $read_fh;
            return $on_complete->({
                available => 1,
                artifacts => [{
                    kind => ref($candidate_tracks) eq 'ARRAY'
                        ? 'resolved-lastfm-evidence-v1' : 'semantic-evidence-v1',
                    path => $path,
                    sha256 => $sha256,
                }],
                diagnostic => '',
                statistics => { requests => 0 + $requests, failures => 0 + $failures, edges => scalar @edges },
            });
        }

        my $source = shift @requests;
        $requests++;
        if ($source->{kind} eq 'track') {
            _log_info(sprintf('Last.fm: requesting similar tracks for "%s - %s"%s',
                $source->{artist}, $source->{title},
                $source->{recording_mbid} ? ' using recording MBID ' . $source->{recording_mbid} : ''));
            return Plugins::LastMix::LFM->getSimilarTracks(sub {
                my $result = shift;
                _log_debug('Last.fm response JSON: ' . _safe_json($result));
                if (!ref($result) || ref($result) ne 'HASH' || $result->{error}) {
                    _log_warning(sprintf('Last.fm request failed for similar tracks "%s - %s"; continuing without this result',
                        $source->{artist}, $source->{title}));
                    $failures++; push @errors, 'LASTFM_TRACK_FAILED'; return $next->();
                }
                my $rank = 0;
                my $similar = $result->{similartracks}{track};
                $similar = [] unless ref($similar) eq 'ARRAY';
                for my $track (@$similar) {
                    next unless ref($track) eq 'HASH' && $track->{name} && ref($track->{artist}) eq 'HASH' && $track->{artist}{name};
                    last if ++$rank > 25;
                    push @edges, _edge(
                        'LastMix track.getSimilar', _recording_entity($source->{id}, $source->{artist}, $source->{title}, $source->{recording_mbid}),
                        _recording_entity(undef, $track->{artist}{name}, $track->{name}, $track->{mbid}), 'endpoint_local', $rank, $track->{match},
                    );
                }
                _log_info(sprintf('Last.fm: got %d similar tracks for "%s - %s"',
                    $rank, $source->{artist}, $source->{title}));
                if (@$similar) {
                    _log_debug(sprintf('Last.fm similar tracks for "%s - %s" (%d): %s',
                        $source->{artist}, $source->{title}, $rank,
                        join(', ', map { ($_->{artist}{name} || '') . ' - ' . ($_->{name} || '')
                            . (defined $_->{match} ? ' (' . $_->{match} . ')' : '') } @$similar[0 .. ($#$similar < 24 ? $#$similar : 24)])));
                }
                $next->();
            }, {
                artist => $source->{artist}, title => $source->{title}, mbid => $source->{recording_mbid},
            });
        }
        _log_info(sprintf('Last.fm: requesting similar artists for "%s"%s',
            $source->{artist}, $source->{artist_mbid} ? ' using artist MBID ' . $source->{artist_mbid} : ''));
        return Plugins::LastMix::LFM->getSimilarArtists(sub {
            my $result = shift;
            _log_debug('Last.fm response JSON: ' . _safe_json($result));
            if (!ref($result) || ref($result) ne 'HASH' || $result->{error}) {
                _log_warning(sprintf('Last.fm request failed for similar artists "%s"; continuing without this result',
                    $source->{artist}));
                $failures++; push @errors, 'LASTFM_ARTIST_FAILED'; return $next->();
            }
            my $rank = 0;
            my $similar = $result->{similarartists}{artist};
            $similar = [] unless ref($similar) eq 'ARRAY';
            for my $artist (@$similar) {
                next unless ref($artist) eq 'HASH' && $artist->{name};
                last if ++$rank > 25;
                my $source_entity = _artist_entity($source->{artist}, $source->{artist_mbid});
                my $candidate = _artist_entity($artist->{name}, $artist->{mbid});
                push @edges, _edge('LastMix artist.getSimilar', $source_entity, $candidate, 'endpoint_local', $rank, $artist->{match});
                push @edges, _edge('LastMix artist.getSimilar', $source_entity, $candidate, 'collection_fallback', $rank, $artist->{match});
            }
            _log_info(sprintf('Last.fm: got %d similar artists for "%s"', $rank, $source->{artist}));
            if (@$similar) {
                _log_debug(sprintf('Last.fm similar artists for "%s" (%d): %s',
                    $source->{artist}, $rank,
                    join(', ', map { ($_->{name} || '')
                        . (defined $_->{match} ? ' (' . $_->{match} . ')' : '') } @$similar[0 .. ($#$similar < 24 ? $#$similar : 24)])));
            }
            $next->();
        }, { artist => $source->{artist}, mbid => $source->{artist_mbid} });
    };
    $next->();
}

sub guidance_provider_log_events_v1 {
    my ($events, $context) = @_;
    for my $event (@{ref($events) eq 'ARRAY' ? $events : []}) {
        next unless ref($event) eq 'HASH';
        my $message = _render_log_event($event);
        next unless length $message;
        my $level = $event->{level} || 'warning';
        $level eq 'debug' ? _log_debug($message)
            : $level eq 'info' ? _log_info($message)
            : $level eq 'error' ? _log_error($message)
            : _log_warning($message);
        if (($event->{event} || '') eq 'lastfm_lookup_failed') {
            my $details = ref($event->{details}) eq 'HASH' ? $event->{details} : {};
            _log_debug('Last.fm lookup failure details: ' . _safe_json({
                operation => $event->{operation}, source => $event->{source},
                cache_state => $event->{cache_state}, error => $details->{error},
            }));
        }
    }
    return 1;
}

sub _render_log_event {
    my $event = shift;
    my $name = $event->{event} || '';
    my $source = ref($event->{source}) eq 'HASH' ? $event->{source} : {};
    my $details = ref($event->{details}) eq 'HASH' ? $event->{details} : {};
    my $operation = $event->{operation} || '';
    my $label = $source->{label} || '';
    my $count = 0 + ($event->{result_count} || 0);
    if ($name eq 'lastfm_prepare_started') {
        return sprintf('Last.fm guidance: source=%s, anchors=%d, track lookups=%d, artist lookups=%d',
            $details->{source} || 'API Key', $details->{anchors} || 0,
            $details->{track_lookups} || 0, $details->{artist_lookups} || 0);
    }
    if ($name eq 'lastfm_lookup_requested') {
        my $identity = ($source->{identity_kind} || '') eq 'recording_mbid' ? 'recording MBID'
            : ($source->{identity_kind} || '') eq 'artist_mbid' ? 'artist MBID'
            : $source->{identity_kind} || 'MBID';
        return sprintf('Last.fm: requesting similar %s for "%s"%s',
            $operation eq 'artist.getSimilar' ? 'artists' : 'tracks', $label,
            $source->{mbid} ? ' using ' . $identity . ' ' . $source->{mbid} : '');
    }
    if ($name eq 'lastfm_lookup_completed') {
        if (($event->{cache_state} || '') eq 'stale_offline') {
            return sprintf('Last.fm: using stale offline similar %s for "%s" (%d results)',
                $operation eq 'artist.getSimilar' ? 'artists' : 'tracks', $label, $count);
        }
        return sprintf($event->{cache_state} && $event->{cache_state} eq 'hit'
                ? 'Last.fm: returning cached similar %s for "%s" (%d results)'
                : 'Last.fm: got %d similar %s for "%s"',
            $event->{cache_state} && $event->{cache_state} eq 'hit'
                ? ($operation eq 'artist.getSimilar' ? 'artists' : 'tracks')
                : $count,
            $event->{cache_state} && $event->{cache_state} eq 'hit'
                ? $label : ($operation eq 'artist.getSimilar' ? 'artists' : 'tracks'),
            $event->{cache_state} && $event->{cache_state} eq 'hit' ? $count : $label);
    }
    return 'Last.fm request JSON: ' . _safe_json($details->{request})
        if $name eq 'lastfm_request_json';
    return 'Last.fm response JSON: ' . _safe_json($details->{results})
        if $name eq 'lastfm_response_json';
    if ($name eq 'lastfm_lookup_failed') {
        return sprintf('Last.fm request failed for similar %s "%s"; continuing without this result',
            $operation eq 'artist.getSimilar' ? 'artists' : 'tracks', $label);
    }
    if ($name eq 'lastfm_persistence_skipped' && ($event->{cache_state} || '') eq 'budget_exhausted') {
        return sprintf('Last.fm: did not store %s for "%s" because the configured data limit was reached',
            $operation eq 'artist.getSimilar' ? 'similar artists' : 'similar tracks', $label);
    }
    if ($name eq 'lastfm_prepare_completed') {
        return sprintf('Last.fm guidance prepared: requests=%d, cache hits=%d, failures=%d, relations=%d',
            $details->{requests} || 0, $details->{cache_hits} || 0,
            $details->{failures} || 0, $details->{relations} || $count);
    }
    if ($name eq 'lastfm_scoring_completed') {
        return sprintf('Last.fm scoring: candidates=%d, similar-track supported=%d, similar-artist supported=%d',
            $details->{candidates} || 0, $details->{similar_track_supported} || 0,
            $details->{similar_artist_supported} || 0);
    }
    return '';
}

sub _diagnostic_level {
    my $logger = init_logging();
    return 'warning' unless $logger;
    return 'debug' if eval { $logger->is_debug };
    return 'info' if eval { $logger->is_info };
    return 'warning';
}

sub _safe_json {
    my $value = shift;
    return '{}' unless defined $value;
    my $json = eval { encode_json($value) } || '{}';
    $json =~ s/"(api_key|api_sig)"\s*:\s*"[^"]*"/"$1":"[redacted]"/gi;
    $json =~ s/([?&](?:api_key|api_sig)=)[^&"\\]+/${1}[redacted]/gi;
    return length($json) > 16384 ? substr($json, 0, 16384) . '...' : $json;
}

sub _log_debug { my $logger = init_logging(); $logger->debug($_[0]) if $logger && eval { $logger->is_debug }; }
sub _log_info { my $logger = init_logging(); $logger->info($_[0]) if $logger && eval { $logger->is_info }; }
sub _log_warning { my $logger = init_logging(); $logger->warn($_[0]) if $logger; }
sub _log_error { my $logger = init_logging(); $logger->error($_[0]) if $logger; }

sub _normalize {
    my $value = lc(shift || '');
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/\s+/ /g;
    return $value;
}

sub _recording_entity {
    my ($id, $artist, $title, $mbid) = @_;
    return { kind => 'recording', id => $id || 'recording:' . _normalize($artist) . '|' . _normalize($title), name => $artist, title => $title, (defined $mbid && length $mbid ? (mbid => $mbid) : ()) };
}

sub _artist_entity {
    my ($name, $mbid) = @_;
    return { kind => 'artist', id => 'artist:' . _normalize($name), name => $name, (defined $mbid && length $mbid ? (mbid => $mbid) : ()) };
}

sub _edge {
    my ($algorithm, $source, $candidate, $scope, $rank, $score) = @_;
    return {
        provider => 'last.fm', dataset_or_algorithm => $algorithm,
        source => $source, candidate => $candidate, scope => $scope,
        raw_rank => 0 + $rank,
        (defined $score && $score =~ /^\d+(?:\.\d+)?$/ ? (raw_score => 0 + $score) : ()),
        identity_confidence => 1.0,
        observed_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time())),
        cache_state => 'fresh',
    };
}

sub _resolve_candidate_edges {
    my ($edges, $candidates) = @_;
    $edges = [] unless ref($edges) eq 'ARRAY';
    $candidates = [] unless ref($candidates) eq 'ARRAY';
    my %index = (
        recording_mbid => {}, recording_name => {},
        artist_mbid => {}, artist_name => {},
    );
    for my $candidate (@$candidates) {
        next unless ref($candidate) eq 'HASH';
        my $candidate_id = $candidate->{candidate_id} || $candidate->{id} || '';
        next unless length $candidate_id;
        my $recording_mbid = _normalize($candidate->{recording_mbid});
        push @{$index{recording_mbid}{$recording_mbid}}, $candidate_id
            if length $recording_mbid;
        my $recording_name = _normalize($candidate->{artist}) . "\0"
            . _normalize($candidate->{title});
        push @{$index{recording_name}{$recording_name}}, $candidate_id
            unless $recording_name eq "\0";
        my @artist_mbids = (
            $candidate->{artist_mbid},
            @{ref($candidate->{artist_mbids}) eq 'ARRAY'
                ? $candidate->{artist_mbids} : []},
        );
        for my $artist_mbid (@artist_mbids) {
            $artist_mbid = _normalize($artist_mbid);
            push @{$index{artist_mbid}{$artist_mbid}}, $candidate_id
                if length $artist_mbid;
        }
        my $artist_name = _normalize($candidate->{artist});
        push @{$index{artist_name}{$artist_name}}, $candidate_id
            if length $artist_name;
    }

    my (@resolved, %seen);
    for my $edge (@$edges) {
        next unless ref($edge) eq 'HASH' && ref($edge->{candidate}) eq 'HASH';
        my $candidate = $edge->{candidate};
        my @matches;
        if (($candidate->{kind} || '') eq 'recording') {
            my $mbid = _normalize($candidate->{mbid});
            @matches = @{$index{recording_mbid}{$mbid} || []} if length $mbid;
            if (!@matches) {
                my $key = _normalize($candidate->{name}) . "\0"
                    . _normalize($candidate->{title});
                @matches = @{$index{recording_name}{$key} || []};
            }
        } elsif (($candidate->{kind} || '') eq 'artist') {
            my $mbid = _normalize($candidate->{mbid});
            @matches = @{$index{artist_mbid}{$mbid} || []} if length $mbid;
            if (!@matches) {
                my $name = _normalize($candidate->{name});
                @matches = @{$index{artist_name}{$name} || []};
            }
        }
        for my $candidate_id (@matches) {
            next if $seen{join("\0", $edge->{source}{id} || '', $candidate_id,
                $edge->{source}{kind} || '')}++;
            push @resolved, { %$edge, resolved_candidate_id => $candidate_id };
        }
    }
    return \@resolved;
}

sub _effective_policy {
    my ($policy, $defaults) = @_;
    my %effective;
    # Hosts may override which provider-owned acquisition backend is used. The
    # API key itself never leaves this provider and is supplied only through the
    # child-process environment when the resolved source is API Key.
    $effective{source} = _source(
        exists $policy->{source} ? $policy->{source} : $defaults->{source}
    );
    $effective{lastfm_artist_mode} = _artist_mode(
        exists $policy->{lastfm_artist_mode} ? $policy->{lastfm_artist_mode} : $defaults->{lastfm_artist_mode}
    );
    for my $key (keys %RANGES) {
        my ($minimum, $maximum) = @{$RANGES{$key}};
        my $value = exists $policy->{$key} ? $policy->{$key} : $defaults->{$key};
        die "Invalid Last.fm value for $key" unless defined $value && $value =~ /^\d+$/;
        $value = int($value);
        die "Out-of-range Last.fm value for $key" if $value < $minimum || $value > $maximum;
        $effective{$key} = $value;
    }
    return \%effective;
}

sub _source {
    my $value = shift;
    return $value && $value =~ /^(?:lastmix|api_key)$/ ? $value : $FACTORY_DEFAULTS{source};
}

sub _artist_mode {
    my $value = shift;
    return $value && $value =~ /^(?:target_share|bounded_influence)$/ ? $value : $FACTORY_DEFAULTS{lastfm_artist_mode};
}

sub _retrieval_policy {
    my $value = shift;
    return $value && $value =~ /^(?:online_with_cache|offline_preferred|offline_only)$/
        ? $value : $FACTORY_DEFAULTS{retrieval_policy};
}

sub _storage_scope {
    my $value = shift;
    return $value && $value =~ /^(?:all_returned_artists|local_artists_only)$/
        ? $value : $FACTORY_DEFAULTS{storage_scope};
}

sub _cache_root {
    my $root = $serverprefs->get('cachedir')
        || eval { Slim::Utils::Prefs::dir() }
        || File::Spec->tmpdir();
    my $path = catfile($root, 'LastFmGuidance');
    make_path($path) unless -d $path;
    return $path;
}

sub _graph_store_path { return catfile(_cache_root(), 'lastfm-guidance.sqlite'); }
sub _legacy_cache_path { return catfile(_cache_root(), 'lastfm-guidance-v1.json'); }
sub _root_snapshot_path { return catfile(_cache_root(), 'library-artist-roots-v1.json'); }
sub _graph_request_path { return catfile(_cache_root(), 'graph-request-v1.json'); }
sub _graph_progress_path { return catfile(_cache_root(), 'graph-progress-v1.jsonl'); }
sub _graph_cancel_path { return catfile(_cache_root(), 'graph-cancel'); }

sub _api_key {
    init_preferences();
    return $prefs->get('api_key') || '';
}

sub _lastmix_available {
    return 0 unless eval { require Slim::Utils::PluginManager; 1 };
    return scalar grep { $_ eq 'Plugins::LastMix::Plugin' }
        Slim::Utils::PluginManager->enabledPlugins();
}

sub _program_path {
    my $directory = dirname(__FILE__);
    my $name = $^O eq 'MSWin32' ? 'bliss-guidance-lastfm.exe' : 'bliss-guidance-lastfm';
    return catfile($directory, 'Bin', _platform(), $name);
}

sub _platform {
    return 'windows' if $^O eq 'MSWin32';
    return 'mac' if $^O eq 'darwin';
    my $arch = lc($Config{archname} || '');
    return 'aarch64-linux' if $arch =~ /(?:aarch64|arm64)/;
    return 'armhf-linux' if $arch =~ /(?:armv6|armv7|armhf|gnueabihf)/;
    return 'x86_64-linux';
}

sub _binary_version {
    my $program = shift;
    my $quoted = $program;
    $quoted =~ s/"/\\"/g;
    return eval { qx("$quoted" version --json) } || '';
}

1;
