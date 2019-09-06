use strict;
use warnings;
use feature 'say';
use Tk;
use Tk::PNG;
use Tk::JPEG;
use Data::Dumper;
use Tk::Canvas;
use File::Spec;
use Digest::file qw(digest_file_hex);
use File::Path qw(make_path remove_tree);
use Data::TreeDumper;
use MIME::Types;
use File::Copy 'copy';

use Image::Resize;
use MIME::Base64;
use threads;
use Thread::Queue;
use BerkeleyDB;
use Getopt::Long;

use XML::Twig;

my $twig_ref = XML::Twig->new();
$twig_ref->parsefile('config.xml');
my $twig_root_ref = $twig_ref->root();


my $source_folderpath = File::Spec->canonpath($twig_root_ref->first_child('source')->text());
my $tmp_folderpath    = File::Spec->canonpath($twig_root_ref->first_child('tmp')->text());
my $dst_folderpath    = File::Spec->canonpath($twig_root_ref->first_child('dst')->text());
my $buffer_size_down  = $twig_root_ref->first_child('buffer_size_down')->text();
my $buffer_size_up    = $twig_root_ref->first_child('buffer_size_up')->text();
my $threads_nb        = $twig_root_ref->first_child('threads_nb')->text();

my %special_folders;
for my $folder_elem_ref ($twig_root_ref->descendants('folder')) {
   $special_folders{$folder_elem_ref->att('key')} = [$folder_elem_ref->att('title'), $folder_elem_ref->text()];
}


my %catalog_paths = (accepted => 'accepted.dbm', rejected => 'rejected.dbm', archives => 'archives.dbm', special => 'special.dbm');
my %catalog;


my @legal_archive_names = ('zip', 'rar', '7z');
my $mt                  = MIME::Types->new();

my $queue_in  = Thread::Queue->new();
my $queue_out = Thread::Queue->new();


#command line options
my $verbose = '';
my $rebuild = '';
my $recheck = '';
GetOptions('verbose' => \$verbose, 'rebuild' => \$rebuild, 'recheck' => \$recheck);


#DB funtions -- Begin
sub db_init {
   for my $recname (keys %catalog_paths) {
      say "load db :'$recname'";
      $catalog{$recname} = new BerkeleyDB::Hash(-Filename => $catalog_paths{$recname}, -Flags => DB_CREATE) or die "Cannot open file: '$catalog_paths{$recname}' $!";
   }
}

sub db_close {
   for my $recname (keys %catalog_paths) {
      say "close db :'$recname'";
      $catalog{$recname}->db_close();
   }
}

sub should_skip_archive {
   my ($filename) = @_;
   my $status = $catalog{archives}->db_exists($filename);
   if ($status) {
      return 0;
   }
   else {
      my $val;
      $status = $catalog{archives}->db_get($filename, $val);
      return not $val;
   }
}

sub set_archive_remains {
   my ($filename, $val) = @_;
   my $status = $catalog{archives}->db_put($filename, $val);
   if ($status) {
      die "unable seting in the archive db value :'$val' into '$filename' $!";
   }
}

sub is_file_known {
   my ($hash)  = @_;
   my $status1 = $catalog{accepted}->db_exists($hash);
   my $status2 = $catalog{rejected}->db_exists($hash);
   my $status  = $status1 && $status2;
   return not $status;
}

sub is_accepted {
   my ($hash) = @_;
   my $status = $catalog{accepted}->db_exists($hash);
   return not $status;
}

sub is_rejected {
   my ($hash) = @_;
   my $status = $catalog{rejected}->db_exists($hash);
   return not $status;
}

sub accept_file {
   my ($hash, $filename) = @_;
   my $status = $catalog{accepted}->db_put($hash, $filename);
   if (is_rejected($hash)) {
      $catalog{rejected}->db_del($hash);
   }
   if ($status) {
      die "unable seting in the accepted db value :'$filename' into '$hash' $!";
   }
}


sub reject_file {
   my ($hash, $filename) = @_;
   if (is_accepted($hash)) {
      $catalog{accepted}->db_del($hash);
   }
   my $status = $catalog{rejected}->db_put($hash, $filename);
   if ($status) {
      die "unable seting in the rejected db value :'$filename' into '$hash' $!";
   }
}

sub is_special {
   my ($hash) = @_;
   my $status = $catalog{special}->db_exists($hash);
   return not $status;
}

sub set_special {
   my ($hash, $key, $filename) = @_;
   my $status = $catalog{special}->db_put($hash, "$key,$filename");
   if ($status) {
      die "unable seting in the special db value :'$filename' into '$hash' $!";
   }
}

sub get_special {
   my ($hash) = @_;
   my $result;
   my $status = $catalog{special}->db_get($hash, $result);
   if ($status) {
      die "unable geting '$hash' in the special db values $!";
   }
   return $result;
}


sub dump_dbs {
   my ($dbname) = @_;
   say "$dbname db:";
   my $cursor = $catalog{$dbname}->db_cursor();
   my $key    = '';
   my $val    = '';
   while ($cursor->c_get($key, $val, DB_NEXT) == 0) {
      print "\tKey: " . $key . ", value: " . $val . "\n";
   }
}

#DB funtions -- encoded

#worker job to cache the image rezizing
sub producepic {
   threads->detach();
   while (defined(my $item_ref = $queue_in->dequeue())) {
      my $index = $item_ref->[0];
      my $file  = $item_ref->[1];
      my $x     = $item_ref->[2];
      my $y     = $item_ref->[3];

      last unless -f $file;
      my $res;
      my $ok = 0;
      eval {
         my $im = Image::Resize->new($file);
         my $gd = $im->resize($x, $y);

         #Tk needs base64 encoded image files
         $res = encode_base64($gd->png);
         $ok  = 1;
      };
      $queue_out->enqueue([$index, $ok, $res]);
   }
}


sub scan_new_archives {
   opendir(my $source_folderfh, $source_folderpath) or die "unable to open '$source_folderpath' $!";
   while (my $archivename = readdir $source_folderfh) {
      my $archivepath = File::Spec->catdir($source_folderpath, $archivename);
      next if $archivename =~ /^\./ or -d $archivepath;
      next if should_skip_archive($archivename);
      if ($archivename =~ /\.(\w+)$/) {
         my $extention = lc $1;
         next unless grep { $extention eq $_ } @legal_archive_names;
         my $dest_tmp_folderpath = unarchive($archivename, $extention);
         scan_images($dest_tmp_folderpath, $archivename);
         remove_tree($dest_tmp_folderpath);
      }
   }
   close($source_folderfh);
}

sub scan_images {
   my ($root_folderpath, $archivename) = @_;
   my @files   = sort { $a->{filename} cmp $b->{filename} } add($root_folderpath);
   my $file_nb = @files;
   if ($file_nb) {
      @files   = swipe(@files);
      $file_nb = move($root_folderpath, @files);
   }
   return $file_nb;
}

sub scan_destfolder {
   my ($recheck) = @_;
   my @files = add($dst_folderpath);

   if ($recheck) {
      @files = swipe(@files);
      move($dst_folderpath, @files);
   }
   else {
      for my $item_ref (@files) {
         accept_file($item_ref->{hash}, $item_ref->{filename});
      }
      add_special();
   }

}

sub unarchive {
   my ($archivename, $extention) = @_;
   my $dest_tmp_folderpath = File::Spec->catdir($tmp_folderpath,    $archivename);
   my $src_archivepath     = File::Spec->catdir($source_folderpath, $archivename);
   mkdir $dest_tmp_folderpath;
   my %unarchivers = (
      'zip' => "7z -y -o$dest_tmp_folderpath x $src_archivepath > log.txt 2>&1",
      'rar' => "7z -y -o$dest_tmp_folderpath x $src_archivepath > log.txt 2>&1",
      '7z'  => "7z -y -o$dest_tmp_folderpath x $src_archivepath > log.txt 2>&1",
   );
   system($unarchivers{$extention});
   return $dest_tmp_folderpath;
}

sub add {
   my ($root_folderpath) = @_;
   return if (grep { $root_folderpath eq $_ } map { File::Spec->catdir($dst_folderpath, $_->[1]) } values %special_folders);
   my @results;
   opendir(my $tmpfh, $root_folderpath) or die "unable to open '$root_folderpath' $!";
   while (my $subfilename = readdir $tmpfh) {
      next if $subfilename =~ /^\./;
      my $subfilepath = File::Spec->catfile($root_folderpath, $subfilename);
      if (-d $subfilepath) {
         push @results, add($subfilepath);
      }
      else {
         my $type = $mt->mimeTypeOf($subfilepath);
         unless ($type && $type =~ /^image/) {
            say "skipped because not an image: '$subfilepath'";
            next;
         }
         my $hash = digest_file_hex($subfilepath, 'SHA1');
         if ($recheck or not is_file_known($hash)) {
            if ($recheck and is_special($hash)) {
               my @special = split ',', get_special($hash);
               push @results, {hash => $hash, filename => $subfilepath, status => 0, special => $special[0]};
            }
            else {
               push @results, {hash => $hash, filename => $subfilepath, status => 0};
            }

         }
      }

   }
   return grep { defined $_ } @results;
}

sub add_special {
   my @folders = map { File::Spec->catdir($dst_folderpath, $_->[1]) } values %special_folders;
   for my $key (keys %special_folders) {
      my $folder = File::Spec->catdir($dst_folderpath, $special_folders{$key}[1]);
      opendir(my $tmpfh, $folder) or die "unable to open '$folder' $!";
      while (my $subfilename = readdir $tmpfh) {
         next if $subfilename =~ /^\./;
         my $subfilepath = File::Spec->catfile($folder, $subfilename);
         next if -d $subfilepath;
         my $hash = digest_file_hex($subfilepath, 'SHA1');
         if (is_special($hash)) {
            my $old_filepath = get_special($hash);
            if ($old_filepath ne $subfilepath) {
               unlink $subfilepath;
            }
         }
         else {
            set_special($hash, $key, $subfilepath);
         }
      }
   }

}

sub move {
   my ($root_folderpath, @files) = @_;

   #blacklist the rejected and whitelist the accepted
   my $file_nb = 0;
   for my $item_ref (@files) {
      my $src_filepath = File::Spec->canonpath($item_ref->{filename});
      my $status       = exists $item_ref->{status} && $item_ref->{status};
      if ($status == -1) {
         reject_file($item_ref->{hash}, $item_ref->{filename});
         unlink $src_filepath;
      }
      elsif ($status == 0) {
         $file_nb++;
      }
      elsif ($status == 1) {
         if (exists $item_ref->{special} and $item_ref->{special}) {
            copy_special_file($item_ref->{special}, $src_filepath);
         }

         #verify that the source file is not already in the destination folder
         if (index $src_filepath, File::Spec->canonpath($dst_folderpath)) {
            my $dst_filepath = File::Spec->catfile($dst_folderpath, rename_dest_files(File::Spec->abs2rel($item_ref->{filename}, $root_folderpath)));
            say "copying source:'$src_filepath' \tto '$dst_filepath'";
            $dst_filepath = check_dest($dst_filepath);
            my ($volume, $dirs) = File::Spec->splitpath($dst_filepath);
            make_path($dirs);
            rename $src_filepath, $dst_filepath;
            accept_file($item_ref->{hash}, $dst_filepath);
         }
      }
   }
   return $file_nb;
}

sub rename_dest_files {
   my ($filename) = @_;
   $filename =~ s/ /_/g;
   $filename = lc $filename;
   return $filename;
}

sub copy_special_file {
   my ($key, $src_filepath) = @_;
   my $dst_folder = File::Spec->catdir($dst_folderpath, $special_folders{$key}[1]);
   make_path($dst_folder);
   my $hash = digest_file_hex($src_filepath, 'SHA1');
   if (is_special($hash)) {
      my $current_special_filepath = get_special($hash);
      unless (index $current_special_filepath, $dst_folder) {
         say "special '$src_filepath' already in '$current_special_filepath'";
         return;
      }
      else {
         unlink $current_special_filepath;
         say "delete special '$current_special_filepath'";
      }
   }
   if ($src_filepath =~ /\.([^\.]+)$/) {
      my $ext          = lc $1;
      my $index        = get_special_index($dst_folder);
      my $dst_filepath = File::Spec->catfile($dst_folder, sprintf "%04d.%s", $index, $ext);
      say "special source '$src_filepath'\tto '$dst_filepath'";
      copy($src_filepath, $dst_filepath) or die "Copy failed: $!";
      set_special($hash, $key, $dst_filepath);
   }
}

sub check_dest {
   my ($dst_filepath) = @_;
   if (-f $dst_filepath and $dst_filepath =~ /(.+)(\.\w+)$/) {
      my $i = 1;
      $dst_filepath = $1 . "[$i]" . $2;
      while (-f $dst_filepath and $dst_filepath =~ /(.+)\[\d+\](\.\w+)$/ and $i < 1000) {
         $dst_filepath = $1 . "[$i]" . $2;
         $i++;
      }
      say "\t\t destination exists => $dst_filepath";
   }
   return $dst_filepath;
}

sub get_special_index {
   my ($dst_folder) = @_;
   my $max = -1;
   opendir(my $dst_folderfh, $dst_folder) or die "unable to open '$dst_folder' $!";
   while (readdir $dst_folderfh) {
      if (/(\d+)\.\w+/) {
         $max = $max > $1 ? $max : $1;
      }
   }
   return $max + 1;
}

sub swipe {
   my (@to_sort) = @_;
   return unless @to_sort;

   my $mw = MainWindow->new;
   my %max;
   $max{x} = $mw->screenwidth;
   $max{y} = $mw->screenheight;
   my @items;
   my $i     = 0;
   my $i_ref = \$i;


   $mw->geometry("$max{x}x$max{y}");
   my $frame  = $mw->Frame(-background => 'black')->pack(-expand => 1, -fill => "both");
   my $canvas = $frame->Canvas()->pack(-expand => 1, -fill => "both");

   my $loadpic_sub = sub {
      my ($force) = @_;
      my $i = $$i_ref - $buffer_size_up > 0           ? $$i_ref - $buffer_size_up   : 0;
      my $j = $$i_ref + $buffer_size_down < $#to_sort ? $$i_ref + $buffer_size_down : $#to_sort;
      for my $k ($i .. $j) {
         if ($force) {
            delete $to_sort[$k]{resizing} if exists $to_sort[$k]{resizing};
            delete $to_sort[$k]{data}     if exists $to_sort[$k]{data};
            delete $to_sort[$k]{ok}       if exists $to_sort[$k]{ok};
         }
         unless (exists $to_sort[$k]{resizing} and $to_sort[$k]{resizing}) {
            $queue_in->enqueue([$k, $to_sort[$k]{filename}, $max{x}, $max{y}]);
            $to_sort[$k]{resizing} = 1;
         }
      }
      if ($i - 1 >= 0 and exists $to_sort[$i - 1]{data}) {
         delete $to_sort[$i - 1]{resizing};
         delete $to_sort[$i - 1]{data};
         delete $to_sort[$i - 1]{ok};
      }
      while (defined(my $item_ref = $queue_out->dequeue_nb())) {
         my $index = $item_ref->[0];
         $to_sort[$index]{data}     = $item_ref->[2];
         $to_sort[$index]{ok}       = $item_ref->[1];
         $to_sort[$index]{resizing} = 0;

      }
      while (not exists $to_sort[$$i_ref]{data}) {
         my $item_ref = $queue_out->dequeue();
         my $index    = $item_ref->[0];
         $to_sort[$index]{data}     = $item_ref->[2];
         $to_sort[$index]{ok}       = $item_ref->[1];
         $to_sort[$index]{resizing} = 0;
      }
   };


   my $update_sub = sub {
      my ($force) = @_;
      &$loadpic_sub($force);


      # make the title of the Main Windows
      my $title = "$to_sort[$$i_ref]{filename}  ($$i_ref/$#to_sort) :";
      if (exists $to_sort[$$i_ref]{special} and $to_sort[$$i_ref]{special}) {
         $title .= " [" . $special_folders{$to_sort[$$i_ref]{special}}[0] . "]";
      }
      $mw->title($title);
      $canvas->delete(@items);
      $items[0] = $canvas->createRectangle(0,           0, $max{x} / 2, $max{y}, -fill => "red");
      $items[1] = $canvas->createRectangle($max{x} / 2, 0, $max{x},     $max{y}, -fill => "green");
      if ($to_sort[$$i_ref]{ok}) {
         my $image = $canvas->Photo(-data => $to_sort[$$i_ref]{data}, -format => 'png');
         $items[2] = $canvas->createImage($max{x} / 2 + $max{x} / 2 * $to_sort[$$i_ref]{status}, $max{y} / 2, -image => $image);
      }

   };

   my $goright_sub = sub {
      $canvas->move($items[2], $max{x} / 2, 0);
      $to_sort[$$i_ref]{status}++ if $to_sort[$$i_ref]{status} < 1;
   };

   my $goleft_sub = sub {
      $canvas->move($items[2], -$max{x} / 2, 0);
      $to_sort[$$i_ref]{status}-- if $to_sort[$$i_ref]{status} > -1;
   };

   my $goup_sub = sub {
      if ($$i_ref > 1) {
         $$i_ref--;
         &$update_sub();
      }
   };
   my $godown_sub = sub {
      if ($$i_ref < $#to_sort) {
         $$i_ref++;
         &$update_sub();
      }
   };

   my $pass_sub = sub {
      if ($to_sort[$$i_ref]{status} != 0) {
         &$godown_sub();
      }
   };


   my $execution_sub = sub {
      for my $i ($$i_ref .. $#to_sort) {
         $to_sort[$i]{status} = -1;
      }
      $mw->destroy();
   };

   my $resize_sub = sub {
      if ($mw->geometry() =~ /^(\d+)x(\d+)/) {
         $max{x} = $1;
         $max{y} = $2;
      }
      &$update_sub(1);
   };

   my $special_sub_factory = sub {
      my ($key) = @_;
      return sub {
         $to_sort[$$i_ref]{special} = $key;
         &$goright_sub();
         &$godown_sub();
      };
   };

   $mw->bind('<KeyPress-d>',   $goright_sub);
   $mw->bind('<KeyRelease-d>', $godown_sub);
   $mw->bind('<KeyPress-a>',   $goleft_sub);
   $mw->bind('<KeyRelease-a>', $godown_sub);
   $mw->bind('<KeyPress-r>',   $resize_sub);
   $mw->bind('<KeyRelease-w>', $goup_sub);
   $mw->bind('<KeyRelease-s>', $godown_sub);
   $mw->bind('<KeyRelease-e>', $execution_sub);
   $mw->bind('<KeyRelease-q>', sub { $mw->destroy() });

   for my $key (keys %special_folders) {
      $mw->bind("<KeyRelease-$key>", &$special_sub_factory($key));
   }


   &$update_sub();

   MainLoop;

   return @to_sort;
}


#main

db_init();

#many worker
for (1 .. $threads_nb) {
   threads->create('producepic');
}
if ($rebuild) {
   scan_destfolder();
}
elsif ($recheck) {
   scan_destfolder(1);
}
else {
   scan_new_archives();
}

if ($verbose) {
   for my $name (sort keys %catalog) {
      dump_dbs($name);
   }
}

db_close();

exit 0;
