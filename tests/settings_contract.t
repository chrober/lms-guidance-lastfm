use strict;
use warnings;
use Test::More;
use lib '.';

{
    package TestPrefs;
    sub new { bless { values => {} }, shift }
    sub init {
        my ($self, $defaults) = @_;
        $self->{values}{$_} = $defaults->{$_}
            for grep { !exists $self->{values}{$_} } keys %{$defaults};
    }
    sub get { $_[0]->{values}{$_[1]} }
    sub set { $_[0]->{values}{$_[1]} = $_[2] }

    package Slim::Utils::Prefs;
    my %prefs;
    sub preferences { $prefs{$_[0]} ||= TestPrefs->new }
    $INC{'Slim/Utils/Prefs.pm'} = __FILE__;

    package Slim::Web::Settings;
    sub import { }
    sub new { bless {}, shift }
    $INC{'Slim/Web/Settings.pm'} = __FILE__;
}

require 'LastFmGuidance/Provider.pm';
$INC{'Plugins/LastFmGuidance/Provider.pm'} = $INC{'LastFmGuidance/Provider.pm'};
require 'LastFmGuidance/Settings.pm';

is(Plugins::LastFmGuidance::Settings->name, 'PLUGIN_LASTFMGUIDANCE_NAME', 'provider has its own settings title');
is(Plugins::LastFmGuidance::Settings->page,
    'plugins/LastFmGuidance/settings/lastfmguidance.html',
    'provider owns its separate settings template');

open my $template, '<', 'LastFmGuidance/HTML/EN/plugins/LastFmGuidance/settings/lastfmguidance.html'
    or die "Cannot read settings template: $!";
my $template_source = do { local $/; <$template> };
like($template_source, qr/settings\/footer\.html/, 'settings template includes the standard explicit Save footer');
like($template_source, qr/pref_source/, 'settings page renders the LastMix/API Key source selector');
like($template_source, qr/pref_api_key/, 'settings page contains the conditional API key field');
like($template_source, qr/lastfm-guidance-source/, 'settings page identifies the source selector for conditional visibility');

done_testing;
