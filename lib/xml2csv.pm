package xml2csv;
use Exporter;
use strict;
use warnings;
use XML::Twig;
use feature qw(say);

our @EXPORT= qw(parse_xml convert2csv);

sub parse_xml {
  my ($filename) = @_;
  my $data_ref = {};
  my $twig_ref=XML::Twig->new(
    twig_handlers =>
    { '/configuration' => sub {
        $data_ref->{destinations}=[split /,/ , uc $_->att('destinations')];},
     '/configuration/database' => sub {
       my $database_ref= { name => $_->att('name'), records =>[ map {_get_children($_)} $_->children()]};
       push @{$data_ref->{databases}}, $database_ref;}
    }
  );
  $twig_ref->parsefile($filename);
  return $data_ref;
}

sub _get_children {
  my ($elem_ref) = @_;
  my $record_ref = {_fields => $elem_ref->atts(), _name => uc $elem_ref->gi(),_children => []} ;
  foreach my $child_ref ($elem_ref->children()) {
    push @{$record_ref->{_children}}, _get_children($child_ref);
  }
  return $record_ref;
}

sub convert2csv {
  my ($data_ref, $fh) = @_;
  unless ($fh) {
    $fh = *STDOUT;
  };
  foreach my $record_ref (@{$data_ref->{records}}) {
    _print_records($record_ref,$fh);
  }

}

sub _print_records {
  my ($data_ref, $fh) = @_;
  print $fh $data_ref->{_name};
  foreach my $key ( keys %{$data_ref->{_fields}}) {
    my $value = $data_ref->{_fields}{$key};
    $key = uc $key;
    print $fh ",$key='$value'";
  }
  print $fh "\n";
  foreach my $record_ref (@{$data_ref->{_children}}) {
    _print_records($record_ref,$fh);
  }
}
#EOF
1;
