use strict;
use warnings;
use Template;
use Template::Namespace::Constants;
use File::Find qw(find);
use Data::TreeDumper ;
use XML::Simple qw(:strict);
use File::Spec::Win32;

# Building context

my %context = ( hostname=>'server1',
				platform=>'platform1',
				user=>$ENV{USERNAME},
				ip=>'192.168.0.1',
				type=>'DTS');

# Building the data

my %data=(context=>\%context);


my $datacallback = sub 
{
	if( -f && /\.xml$/)
	{
		my $namespace=substr $_, 0 , -4;
		my ($volume,$directories,$file) =File::Spec->splitpath($File::Find::name);
		my @dirs = File::Spec->splitdir($directories);
		splice @dirs, -1 ;
		splice @dirs, 0, 1 ;
		my $dataref=\%data;
		foreach my $dir (@dirs)
		{
			$dataref=$dataref->{$dir};
		}
		$dataref->{$namespace}=readdatafile($_);
	}
	elsif( -d && $_ ne ".")
	{
		my ($volume,$directories,$file) =File::Spec->splitpath($File::Find::name);
		my @dirs = File::Spec->splitdir($directories);
		splice @dirs, -1 ;
		splice @dirs, 0, 1 ;
		my $dataref=\%data;
		foreach my $dir (@dirs)
		{
			$dataref=$dataref->{$dir};
		}
		my %newlevel;
		$dataref->{$_}=\%newlevel;
		$dataref=$dataref->{$_};
	}
};

#sub for building a hash from the data file content
sub readdatafile
{
	my $filename=shift;
	my %hash=(filename=>$filename);
	my $xml = new XML::Simple;
	my $config = $xml->XMLin($filename,KeyAttr => { scalar => 'name', array =>'name'  }, ForceArray => ['filter','scalar','array']);
	
	print DumpTree($config,$filename);

	
	filter(\%hash,$config);
	
	return \%hash;
};

sub filter
{
	my $hashref = shift;
	my $xmltree = shift;
	
	#working on scalars
	my @scalars = keys %{$xmltree-> {'scalar'}};
	foreach my $item (@scalars)
	{
		#print "item = $item\n";
		my $filters = $xmltree->{'scalar'}{$item}{'filter'};
		foreach my $filter ( @$filters)
		{
			my $match=1;
			foreach my $att (keys %$filter)
			{
				if($att ne 'value')
				{
					$match=0 if(exists $data{'context'}{$att} and $data{'context'}{$att} eq $filter->{$att});
					#print "att = $att value=$filter->{$att} match=$match\n";
				}
			}
			if($match == 1)
			{
				$hashref->{$item}=$filter->{'value'}
			}
		}
	}
	
	#working on arrays
	my @arrays = keys %{$xmltree-> {'array'}};
	foreach my $item (@arrays)
	{
		#print "item = $item\n";
		my $filters = $xmltree->{'array'}{$item}{'filter'};
		foreach my $filter ( @$filters)
		{
			my $match=1;
			foreach my $att (keys %$filter)
			{
				if($att ne 'value')
				{
					$match=0 if(exists $data{'context'}{$att} and $data{'context'}{$att} eq $filter->{$att});
					#print "att = $att value=$filter->{$att} match=$match\n";
				}
			}
			if($match == 1)
			{
				if(exists $hashref->{$item})
				{
					push @{$hashref->{$item}} , $filter->{'value'};
				}
				else
				{
					$hashref->{$item}=[$filter->{'value'}];
				}
			}
		}
	}
}

find($datacallback,'Data');

print DumpTree(\%data,'data');

#Gathering template names


my @templatefiles;
	
my $callback = sub
{
	return unless -f;
	my ($volume,$directories,$file) =File::Spec->splitpath( $File::Find::name);
	my @dirs = File::Spec->splitdir( $directories );
	if(scalar(@dirs) == 2 )
	{
		push (@templatefiles, $file);
	}
	else
	{
		shift @dirs;
		my $directory = File::Spec->catdir( @dirs );
		my $full_path = File::Spec->catpath( $volume, $directory, $file );
		push (@templatefiles, $full_path);
	}
};

find($callback,'Templates');

#TT part

print "Templates:\n";

my $tt = Template->new
({
    INCLUDE_PATH => [ 'Misc','Templates' ],
	OUTPUT_PATH  => "Output",
	STRICT => 1,
	TRIM => 0,
	RECURSION => 0,
	PRE_PROCESS => 'tt_header.tt',
	NAMESPACE => {context => Template::Namespace::Constants->new(%context)}
});

foreach my $file (@templatefiles)
{
	print "$file\n";
	$tt->process("$file",\%data,"$file")|| die $tt->error;
}

