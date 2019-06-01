package xml2csv;
use Exporter;
use strict;
use warnings;
use XML::Twig;

our @EXPORT= qw(parse_xml);

sub parse_xml {
  my ($filename) = @_;
  my $twig_ref=XML::Twig->new();
  $twig_ref->parsefile($filename);
  return $twig_ref;
}





#EOF
1;
