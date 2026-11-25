package Plugins::LastFmGuidance::DeferredPersistence;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    for my $key (qw(is_scanning has_pending launch subscribe unsubscribe schedule on_error)) {
        die "Missing deferred persistence callback $key" unless ref($args{$key}) eq 'CODE';
    }
    return bless { %args }, $class;
}

sub start {
    my ($self) = @_;
    $self->{stopped} = 0;
    $self->{listener} = sub { $self->trigger };
    $self->{subscribe}->($self->{listener});
    $self->trigger;
}

sub trigger {
    my ($self) = @_;
    return if $self->{stopped} || $self->{is_scanning}->();
    return if $self->{process};
    return unless $self->{has_pending}->();
    my $process = eval { $self->{launch}->() };
    unless ($process) {
        my $error = $@ || 'cannot start deferred persistence';
        $self->{cleanup}->() if $self->{cleanup};
        $self->{on_error}->($error);
        return;
    }
    $self->{process} = $process;
    $self->{schedule}->(sub { $self->_poll });
}

sub scan_started {
    my ($self) = @_;
    return if $self->{stopped} || !$self->{process} || $self->{cancel_requested};
    $self->{cancel_requested} = 1;
    eval { $self->{process}->die };
}

sub _poll {
    my ($self) = @_;
    return if $self->{stopped} || !$self->{process};
    if ($self->{cancel_requested} || $self->{is_scanning}->()) {
        $self->scan_started unless $self->{cancel_requested};
        if ($self->{process}->alive) {
            $self->{schedule}->(sub { $self->_poll });
            return;
        }
        delete $self->{process};
        delete $self->{cancel_requested};
        $self->{cleanup}->() if $self->{cleanup};
        $self->trigger unless $self->{is_scanning}->();
        return;
    }
    if ($self->{process}->alive) {
        $self->{schedule}->(sub { $self->_poll });
        return;
    }
    my $exit = $self->{process}->exit_code;
    my $signal = $self->{process}->exit_signal;
    delete $self->{process};
    $self->{cleanup}->() if $self->{cleanup};
    if (!defined($exit) || !defined($signal) || $exit != 0 || $signal != 0) {
        $self->{on_error}->('deferred persistence worker failed; queued data retained');
        return;
    }
    $self->trigger;
}

sub stop {
    my ($self) = @_;
    $self->{stopped} = 1;
    $self->{unsubscribe}->($self->{listener}) if $self->{listener};
    delete $self->{listener};
    eval { $self->{process}->die } if $self->{process};
    delete $self->{process};
    $self->{cleanup}->() if $self->{cleanup};
}

1;
