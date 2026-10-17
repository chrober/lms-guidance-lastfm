use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use Test::More;

my $root = File::Spec->catdir($Bin, '..');
my $pin_path = File::Spec->catfile($root, 'LastFmGuidance', 'Bin', 'NATIVE_RELEASE');
my $workflow_path = File::Spec->catfile($root, '.github', 'workflows', 'release.yml');

ok(-f $pin_path, 'native release pin is tracked with the plugin source');
my $pin = '';
if (-f $pin_path) {
    open my $pin_fh, '<', $pin_path or die "Cannot read $pin_path: $!";
    local $/;
    $pin = <$pin_fh>;
    close $pin_fh;
    $pin =~ s/\s+\z//;
}
like($pin, qr/^v\d+\.\d+\.\d+$/, 'native release pin names a semantic-version release tag');

open my $workflow_fh, '<', $workflow_path or die "Cannot read $workflow_path: $!";
local $/;
my $workflow = <$workflow_fh>;
close $workflow_fh;

like(
    $workflow,
    qr{LastFmGuidance/Bin/NATIVE_RELEASE},
    'release workflow reads the tracked native release pin',
);
unlike(
    $workflow,
    qr{NATIVE_RELEASE_INPUT:-v\d+\.\d+\.\d+},
    'release workflow has no second hard-coded native fallback',
);

done_testing;
