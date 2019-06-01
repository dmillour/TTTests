use Regexp::Grammars;
use Data::TreeDumper ;
use strict;

open(my $fh, '<', 'test.txt' );
my $file = do {local $/; <$fh>};

my $parser = qr{
	<nocontext:>

	<Lines>
	
	<rule: Lines> <[Line]>*
	
	<rule: Line>  <Element>(\n|;)*
	
	<rule: Element>  <Db> | <Record>
	
	<rule: Db>  db <Dbname>

	<rule: Dbname>  \w+
	
	<rule: Record>  <RecordDef> \{ ( <.ws> <[Field]> <.ws> (\n+|;+))* \}
	
	<rule: RecordDef> items | (record)? <RecordName> (id)? <RecordId>?
	
	<rule: RecordName> \w+
	
	<rule: RecordId> \w+
	
	<rule: Field>  <Record> | <FieldDef> = <FieldValue> \n*  
	
	<rule: FieldDef>  ((int|string|float|bool|\w+)\s+)? <FieldName>
	<rule: FieldName>  \w+
	<rule: FieldValue>  [^\n]+
	
	<token: ws> (?:\s+|\#[^\n]*)*
	
}xms;

print "$file\n";
print "==================================\n";

if ($file =~ $parser) {
	my $result_ref = \%/;
	print DumpTree($result_ref,'result');
}
else {
	die "Cannot parse the file!\n" . @!;
}

