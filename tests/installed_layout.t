use strict;
use warnings;
use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;

my $source = File::Spec->catdir($FindBin::Bin, '..', 'LastFmGuidance');
my $stage = tempdir(CLEANUP => 1);
my $installed = File::Spec->catdir($stage, 'Plugins', 'LastFmGuidance');
make_path($installed);
for my $file (qw(Plugin.pm Provider.pm Settings.pm strings.txt)) {
    copy(File::Spec->catfile($source, $file), File::Spec->catfile($installed, $file))
        or die "Could not stage $file from $source into $installed: $!";
}
unshift @INC, $stage;

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

require Plugins::LastFmGuidance::Plugin;
is(Plugins::LastFmGuidance::Plugin->getDisplayName, 'PLUGIN_LASTFMGUIDANCE_NAME', 'plugin loads from the Lyrion Plugins/LastFmGuidance install layout');
is(Plugins::LastFmGuidance::Plugin->guidance_provider_descriptor_v1->{provider_id}, 'lastfm', 'installed plugin loads its companion provider module');

done_testing;
