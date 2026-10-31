package Plugins::LastFmGuidance::PersistenceLog;

use strict;
use warnings;
use File::Spec::Functions qw(catfile);
use JSON::PP qw(decode_json);

sub drain {
    my ($dir, $log, $info) = @_;
    return unless opendir(my $dh, $dir);
    my @files = grep { /^(?:error|info)-\d+-\d+\.json$/ } readdir($dh);
    closedir($dh);
    for my $name (sort @files) {
        my $path = catfile($dir, $name);
        next if -l $path || !-f $path || -s $path > 16384;
        open my $fh, '<:raw', $path or next;
        my $bytes = do { local $/; <$fh> };
        close $fh;
        my $data = eval { decode_json($bytes) };
        next unless ref($data) eq 'HASH';
        if ($name =~ /^error-/) {
            next unless defined $data->{error};
            my $error = $data->{error};
            $error =~ s/[\r\n\x00-\x1f]+/ /g;
            $error = substr($error, 0, 512);
            eval { $log->('Last.fm background persistence failed: ' . $error); 1 } or next;
            if ($error =~ /exceeded the configured storage limit/) {
                my $marker = catfile($dir, 'last-budget-rejection.json');
                my $temporary = $marker . '.' . $$ . '.tmp';
                if (open my $out, '>:raw', $temporary) {
                    print {$out} '{"at":' . time() . '}';
                    close $out;
                    rename $temporary, $marker;
                }
            }
        } else {
            next unless $info && defined $data->{artist}
                && !grep { !defined $data->{$_} || $data->{$_} !~ /^\d+$/ } qw(returned stored excluded_non_library);
            my $artist = substr($data->{artist}, 0, 512);
            $artist =~ s/[\r\n\x00-\x1f]+/ /g;
            my $message = 'Last.fm: stored ' . $data->{stored} . ' of ' . $data->{returned}
                . ' similar artists for "' . $artist . '" (' . $data->{excluded_non_library}
                . ' excluded: not in Lyrion library)';
            eval { $info->($message); 1 } or next;
        }
        unlink $path;
    }
}

sub last_budget_rejection {
    my ($dir) = @_;
    my $path = catfile($dir, 'last-budget-rejection.json');
    return 0 if -l $path || !-f $path || -s $path > 1024;
    open my $fh, '<:raw', $path or return 0;
    my $data = eval { decode_json(do { local $/; <$fh> }) };
    close $fh;
    return ref($data) eq 'HASH' && defined($data->{at}) && $data->{at} =~ /^\d+$/ ? 0 + $data->{at} : 0;
}

1;
