use strict;
use warnings;

package Stash;

use parent 'Template::Stash';

sub set_context {
  my ($self_ref, $context_ref) = @_;
  $self_ref->{_CONTEXT}=$context_ref;
}

sub undefined {
    my ($self_ref, $ident, $args) = @_;
    die "Context not set" unless $self_ref->{_CONTEXT};
    return $self_ref->{_CONTEXT}->get($ident, $args);

}






1;
