use strict;
use warnings;
use Test::More;
use File::Spec;
use lib '.';

{
    package TestPrefs;
    sub new { bless { values => {} }, shift }
    sub init { }
    sub get { $_[0]->{values}{$_[1]} }
    sub set { $_[0]->{values}{$_[1]} = $_[2] }

    package Slim::Utils::Prefs;
    my %prefs;
    sub preferences { $prefs{$_[0]} ||= TestPrefs->new }
    $INC{'Slim/Utils/Prefs.pm'} = __FILE__;

    package Slim::Plugin::Base;
    sub import { }
    sub initPlugin { 1 }
    $INC{'Slim/Plugin/Base.pm'} = __FILE__;

    package main;
    sub WEBUI { 0 }
}

require 'LastFmGuidance/Provider.pm';
$INC{'Plugins/LastFmGuidance/Provider.pm'} = $INC{'LastFmGuidance/Provider.pm'};
require 'LastFmGuidance/Plugin.pm';

is(Plugins::LastFmGuidance::Plugin->getDisplayName, 'PLUGIN_LASTFMGUIDANCE_NAME', 'plugin publishes localized display name');
my $descriptor = Plugins::LastFmGuidance::Plugin->guidance_provider_descriptor_v1;
is($descriptor->{provider_id}, 'lastfm', 'plugin forwards the public provider descriptor');

{
    no warnings qw(redefine once);
    my @received;
    local *Plugins::LastFmGuidance::Provider::guidance_provider_process_environment_v1 = sub {
        @received = @_;
        return { BLISS_GUIDANCE_LASTFM_API_KEY => 'test-key' };
    };
    my $policy = { lastfm_artist_level => 75 };
    my $context = { as_of_unix_seconds => 1 };
    my $environment = Plugins::LastFmGuidance::Plugin->guidance_provider_process_environment_v1($policy, $context);
    is_deeply($environment, { BLISS_GUIDANCE_LASTFM_API_KEY => 'test-key' }, 'plugin forwards launch-only environment map');
    is_deeply(\@received, [$policy, $context], 'plugin removes its class invocant before forwarding environment arguments');
}

done_testing;
