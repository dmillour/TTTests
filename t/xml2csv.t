use strict;
use warnings;

use Test::More tests => 1;
use xml2csv qw(parse_xml);

my $filename_ok='t\xml\xml_ok.xml';

my $twig_ref= xml2csv::parse_xml($filename_ok);
ok($twig_ref);
