use v5.26;
use strict;
use warnings;
use Cpanel::JSON::XS;
use Data::TreeDumper;

my $json = new Cpanel::JSON::XS;

$json = $json->relaxed();

my $json_filename = 'test.json';

open( my $fh, '<', $json_filename ) or die $!;

my @json_string_array = <$fh>;
my $json_string = join '', @json_string_array;

print $json_string;

my $json_ref = $json->decode( $json_string);


print DumpTree($json_ref,'test.json');