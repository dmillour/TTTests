use strict;
use warnings;
use lib 'C:\Users\dmillour\TTTests\lib';
use Test::More tests => 1;
use xml2csv qw(parse_xml convert2csv);
use Data::TreeDumper;

my $filename_ok='t\xml\xml_ok.xml';

my $data_ref= xml2csv::parse_xml($filename_ok);

ok($data_ref);

print DumpTree($data_ref,'data');
xml2csv::convert2csv($data_ref->{databases}[0]);
