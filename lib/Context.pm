use strict;
use warnings;

package Context;

sub new {
    my ($class, @folders)  = @_;

    my $self_ref   = {
        _root  => { },
        _target => undef,
    };

    bless $self_ref, $class;
}

sub get {
    my ($self_ref, $idents_ref, $args) = @_;
    my $return_ref= {};

    sub _get {
      my ($return_ref,$root_ref, $ident, $args_ref, @idents) = @_ ;
      my $value;

      return $root_ref unless $ident;
      die "undefined" unless defined $root_ref;



      my $type = ref $root_ref;
      if ($type eq 'HASH') {
        if ( exists $root_ref->{$ident} ) {
          $return_ref->{$ident} = {};
          $value = $root_ref->{$ident};
        }
        else {
          return undef;
        }
    };
    _get($return_ref,$self_ref->{_root},@$idents_ref);

    return $return_ref;
}

sub _get {
    my ($self_ref, $root_ref, $item, $args) = @_;
    my $rootref = ref $root_ref;

    return undef unless defined($root_ref) and defined($item);


    # or if an attempt is made to access a private member, starting _ or .
    return undef if $PRIVATE && $item =~ /$PRIVATE/;

    if ($atroot || $rootref eq 'HASH') {
        # if $root is a regular HASH or a Template::Stash kinda HASH (the
        # *real* root of everything).  We first lookup the named key
        # in the hash, or create an empty hash in its place if undefined
        # and the $lvalue flag is set.  Otherwise, we check the HASH_OPS
        # pseudo-methods table, calling the code if found, or return undef.

        if (defined($value = $root->{ $item })) {
            return $value unless ref $value eq 'CODE';      ## RETURN
            @result = &$value(@$args);                      ## @result
        }
        elsif ($lvalue) {
            # we create an intermediate hash if this is an lvalue
            return $root->{ $item } = { };                  ## RETURN
        }
        # ugly hack: only allow import vmeth to be called on root stash
        elsif (($value = $HASH_OPS->{ $item })
               && ! $atroot || $item eq 'import') {
            @result = &$value($root, @$args);               ## @result
        }
        elsif ( ref $item eq 'ARRAY' ) {
            # hash slice
            return [@$root{@$item}];                        ## RETURN
        }
    }
    elsif ($rootref eq 'ARRAY') {
        # if root is an ARRAY then we check for a LIST_OPS pseudo-method
        # or return the numerical index into the array, or undef
        if ($value = $LIST_OPS->{ $item }) {
            @result = &$value($root, @$args);               ## @result
        }
        elsif ($item =~ /^-?\d+$/) {
            $value = $root->[$item];
            return $value unless ref $value eq 'CODE';      ## RETURN
            @result = &$value(@$args);                      ## @result
        }
        elsif ( ref $item eq 'ARRAY' ) {
            # array slice
            return [@$root[@$item]];                        ## RETURN
        }
    }

    # NOTE: we do the can-can because UNIVSERAL::isa($something, 'UNIVERSAL')
    # doesn't appear to work with CGI, returning true for the first call
    # and false for all subsequent calls.

    # UPDATE: that doesn't appear to be the case any more

    elsif (blessed($root) && $root->can('can')) {

        # if $root is a blessed reference (i.e. inherits from the
        # UNIVERSAL object base class) then we call the item as a method.
        # If that fails then we try to fallback on HASH behaviour if
        # possible.
        eval { @result = $root->$item(@$args); };

        if ($@) {
            # temporary hack - required to propagate errors thrown
            # by views; if $@ is a ref (e.g. Template::Exception
            # object then we assume it's a real error that needs
            # real throwing

            my $class = ref($root) || $root;
            die $@ if ref($@) || ($@ !~ /Can't locate object method "\Q$item\E" via package "\Q$class\E"/);

            # failed to call object method, so try some fallbacks
            if (reftype $root eq 'HASH') {
                if( defined($value = $root->{ $item })) {
                    return $value unless ref $value eq 'CODE';      ## RETURN
                    @result = &$value(@$args);
                }
                elsif ($value = $HASH_OPS->{ $item }) {
                    @result = &$value($root, @$args);
                }
                elsif ($value = $LIST_OPS->{ $item }) {
                    @result = &$value([$root], @$args);
                }
            }
            elsif (reftype $root eq 'ARRAY') {
                if( $value = $LIST_OPS->{ $item }) {
                   @result = &$value($root, @$args);
                }
                elsif( $item =~ /^-?\d+$/ ) {
                   $value = $root->[$item];
                   return $value unless ref $value eq 'CODE';      ## RETURN
                   @result = &$value(@$args);                      ## @result
                }
                elsif ( ref $item eq 'ARRAY' ) {
                    # array slice
                    return [@$root[@$item]];                        ## RETURN
                }
            }
            elsif ($value = $SCALAR_OPS->{ $item }) {
                @result = &$value($root, @$args);
            }
            elsif ($value = $LIST_OPS->{ $item }) {
                @result = &$value([$root], @$args);
            }
            elsif ($self->{ _DEBUG }) {
                @result = (undef, $@);
            }
        }
    }
    elsif (($value = $SCALAR_OPS->{ $item }) && ! $lvalue) {
        # at this point, it doesn't look like we've got a reference to
        # anything we know about, so we try the SCALAR_OPS pseudo-methods
        # table (but not for l-values)
        @result = &$value($root, @$args);           ## @result
    }
    elsif (($value = $LIST_OPS->{ $item }) && ! $lvalue) {
        # last-ditch: can we promote a scalar to a one-element
        # list and apply a LIST_OPS virtual method?
        @result = &$value([$root], @$args);
    }
    elsif ($self->{ _DEBUG }) {
        die "don't know how to access [ $root ].$item\n";   ## DIE
    }
    else {
        @result = ();
    }

    # fold multiple return items into a list unless first item is undef
    if (defined $result[0]) {
        return                              ## RETURN
        scalar @result > 1 ? [ @result ] : $result[0];
    }
    elsif (defined $result[1]) {
        die $result[1];                     ## DIE
    }
    elsif ($self->{ _DEBUG }) {
        die "$item is undefined\n";         ## DIE
    }

    return undef;
}
