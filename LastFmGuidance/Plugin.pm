package Plugins::LastFmGuidance::Plugin;

use strict;
use base qw(Slim::Plugin::Base);
use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);
use Plugins::LastFmGuidance::Provider;

sub getDisplayName { return 'PLUGIN_LASTFMGUIDANCE_NAME'; }

sub initPlugin {
    my $class = shift;
    Plugins::LastFmGuidance::Provider::init_preferences();
    _load_strings();
    if (main::WEBUI) {
        require 'Plugins/LastFmGuidance/Settings.pm';
        Plugins::LastFmGuidance::Settings->new;
    }
    $class->SUPER::initPlugin();
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

1;
