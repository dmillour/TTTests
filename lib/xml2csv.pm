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
       my $database_ref= bless { name => $_->att('name'), records =>[ map {_get_children($_)} $_->children()]} => 'Database';
       push @{$data_ref->{databases}}, $database_ref;}
    }
  );
  $twig_ref->parsefile($filename);
  return $data_ref;
}

sub _get_children {
  my ($elem_ref) = @_;
  my $record_ref = bless {fields => $elem_ref->atts(), name => uc $elem_ref->gi(),children => []} => 'Record' ;
  foreach my $child_ref ($elem_ref->children()) {
    push @{$record_ref->{children}}, _get_children($child_ref);
  }
  return $record_ref;
}

sub convert2csv {
  my ($data_ref, $fh) = @_;
  unless ($fh) {
    $fh = *STDOUT;
  };
  foreach my $record_ref (@{$data_ref->{records}}) {
    $record_ref->print_records($fh);
  }

}

sub parse_csv {
  my ($filename) = @_;
  my $data_ref = {};
}

sub Record::print_records {
  my ($record_ref, $fh) = @_;
  print $fh $record_ref->{name};
  foreach my $key ( keys %{$record_ref->{fields}}) {
    my $value = $record_ref->{fields}{$key};
    $key = uc $key;
    print $fh ",$key='$value'";
  }
  print $fh "\n";
  foreach my $child_ref (@{$record_ref->{children}}) {
    $child_ref->print_records($fh);
  }
}

#EOF
1;
