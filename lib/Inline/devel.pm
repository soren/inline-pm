package Inline;

use strict;
require 5.005;
$Inline::VERSION = '0.43';

use AutoLoader 'AUTOLOAD';
use Inline::denter;
use Config;
use Carp;
use Cwd qw(abs_path cwd);

my %CONFIG = ();
my @DATA_OBJS = ();
my $INIT = 0;
my $version_requested = 0;
my $version_printed = 0;
my $untaint = 0;
my $safemode = 0;
$Inline::languages = undef; #needs to be global for AutoLoaded error messages

my %shortcuts = 
  (
   CLEAN =>        [CLEAN_BUILD_AREA => 1],
   FORCE =>        [FORCE_BUILD => 1],
   INFO =>         [PRINT_INFO => 1],
   VERSION =>      [PRINT_VERSION => 1],
   NOCLEAN =>      [CLEAN_AFTER_BUILD => 0],
   REPORTBUG =>    [REPORTBUG => 1],
   UNTAINT =>      [UNTAINT => 1],
   SAFE =>         [SAFEMODE => 1],
   UNSAFE =>       [SAFEMODE => 0],
   GLOBAL =>       [GLOBAL_LOAD => 1],
   _INSTALL_ =>    [_INSTALL_ => 1],
   SITE_INSTALL => undef,  # No longer supported.
  );

my $default_config = 
  {
   NAME => '',
   AUTONAME => -1,
   VERSION => '',
   DIRECTORY => '',
   WITH => [],
   CLEAN_AFTER_BUILD => 1,
   CLEAN_BUILD_AREA => 0,
   FORCE_BUILD => 0,
   PRINT_INFO => 0,
   PRINT_VERSION => 0,
   REPORTBUG => 0,
   UNTAINT => 0,
   SAFEMODE => -1,
   GLOBAL_LOAD => 0,
   _INSTALL_ => 0,
  };

sub UNTAINT {$untaint}
sub SAFEMODE {$safemode}

#==============================================================================
# This is where everything starts.
#==============================================================================
sub import {
    local ($/, $") = ("\n", ' '); local ($\, $,);

    my $o;
    my ($pkg, $script) = caller;
    $pkg =~ s/^.*[\/\\]//;
    my $class = shift;
    if ($class ne 'Inline') {
	croak M01_usage_use($class) if $class =~ /^Inline::/;
	croak M02_usage();
    }

    $CONFIG{$pkg}{template} ||= $default_config;

    return unless @_;
    &create_config_file(), return 1 if $_[0] eq '_CONFIG_';
    goto &maker_utils if $_[0] =~ /^(install|makedist|makeppd)$/i;

    my $control = shift;

    if ($control eq 'with') {
	return handle_with($pkg, @_);
    }
    elsif ($control eq 'Config') {
	return handle_global_config($pkg, @_);
    }
    elsif (exists $shortcuts{uc($control)}) {
	handle_shortcuts($pkg, $control, @_);
	$version_requested = $CONFIG{$pkg}{template}{PRINT_VERSION};
	return;
    }
    elsif ($control =~ /^\S+$/ and $control !~ /\n/) {
	my $language_id = $control;
	my $option = shift || '';
	my @config = @_;
	my $next = 0;
	for (@config) {
	    next if $next++ % 2;
	    croak M02_usage() if /[\s\n]/;
	}
	$o = bless {}, $class;
	$o->{INLINE}{version} = $Inline::VERSION;
	$o->{API}{pkg} = $pkg;
	$o->{API}{script} = $script;
	$o->{API}{language_id} = $language_id;
	if ($option =~ /^(FILE|BELOW)$/ or
	    not $option and
	    defined $INC{"Inline/Files.pm"} and
	    Inline::Files::get_filename($pkg)
	   ) {
	    $o->read_inline_file;
	    $o->{CONFIG} = handle_language_config(@config);
	}
	elsif ($option eq 'DATA' or not $option) {
	    $o->{CONFIG} = handle_language_config(@config);
	    push @DATA_OBJS, $o;
	    return;
	}
	elsif ($option eq 'Config') {
	    $CONFIG{$pkg}{$language_id} = handle_language_config(@config);
	    return;
	}
	else {
	    $o->receive_code($option);
	    $o->{CONFIG} = handle_language_config(@config);
	}
    }
    else {
	croak M02_usage();
    }
    $o->glue;
}

#==============================================================================
# Run time version of import (public method)
#==============================================================================
sub bind {
    local ($/, $") = ("\n", ' '); local ($\, $,);

    my ($code, @config);
    my $o;
    my ($pkg, $script) = caller;
    my $class = shift;
    croak M03_usage_bind() unless $class eq 'Inline';

    $CONFIG{$pkg}{template} ||= $default_config;

    my $language_id = shift or croak M03_usage_bind();
    croak M03_usage_bind()
      unless ($language_id =~ /^\S+$/ and $language_id !~ /\n/);
    $code = shift or croak M03_usage_bind();
    @config = @_;
	
    my $next = 0;
    for (@config) {
	next if $next++ % 2;
	croak M03_usage_bind() if /[\s\n]/;
    }
    $o = bless {}, $class;
    $o->{INLINE}{version} = $Inline::VERSION;
    $o->{API}{pkg} = $pkg;
    $o->{API}{script} = $script;
    $o->{API}{language_id} = $language_id;
    $o->receive_code($code);
    $o->{CONFIG} = handle_language_config(@config);

    $o->glue;
}

#==============================================================================
# Process delayed objects that don't have source code yet.
#==============================================================================
# This code is an ugly hack because of the fact that you can't use an 
# INIT block at "run-time proper". So we kill the warning for 5.6+ users
# and tell them to use a Inline->init() call if they run into problems. (rare)
my $lexwarn = ($] >= 5.006) ? 'no warnings;' : '';

eval <<END;
$lexwarn
\$INIT = \$INIT; # Needed by Sarathy's patch.
sub INIT {
    \$INIT++;
    &init;
}
END

sub init {
    local ($/, $") = ("\n", ' '); local ($\, $,);

    while (my $o = shift(@DATA_OBJS)) {
	$o->read_DATA;
	$o->glue;
    }
}

sub END {
    warn M51_unused_DATA() if @DATA_OBJS;
    print_version() if $version_requested && not $version_printed;
}

#==============================================================================
# Print a small report about the version of Inline
#==============================================================================
sub print_version {
    return if $version_printed++;
    print STDERR <<END;

    You are using Inline.pm version $Inline::VERSION

END
}

#==============================================================================
# Compile the source if needed and then dynaload the object
#==============================================================================
sub glue {
    my $o = shift;
    my ($pkg, $language_id) = @{$o->{API}}{qw(pkg language_id)};
    my @config = (%{$CONFIG{$pkg}{template}},
		  %{$CONFIG{$pkg}{$language_id} || {}},
		  %{$o->{CONFIG} || {}},
		 );
    @config = $o->check_config(@config);
    $o->fold_options;

    $o->check_installed;
    $o->env_untaint if UNTAINT;
    if (not $o->{INLINE}{object_ready}) {
	$o->check_config_file;                # Final DIRECTORY set here.
	push @config, $o->with_configs;
	my $language = $o->{API}{language};
	croak M04_error_nocode($language_id) unless $o->{API}{code};
	$o->check_module;
    }
    $o->env_untaint if UNTAINT;
    $o->obj_untaint if UNTAINT;
    print_version() if $version_requested;
    $o->reportbug() if $o->{CONFIG}{REPORTBUG};
    if (not $o->{INLINE}{object_ready}
	or $o->{CONFIG}{PRINT_INFO}
       ) {
	eval "require $o->{INLINE}{ILSM_module}";
	croak M05_error_eval('glue', $@) if $@;
	bless $o, $o->{INLINE}{ILSM_module};    
	$o->validate(@config);
    }
    else {
	$o->{CONFIG} = {(%{$o->{CONFIG}}, @config)};
    }
    $o->print_info if $o->{CONFIG}{PRINT_INFO};
    unless ($o->{INLINE}{object_ready} or
	    not length $o->{INLINE}{ILSM_suffix}) {
	$o->build();
	$o->write_inl_file() unless $o->{CONFIG}{_INSTALL_};
    }
    if ($o->{INLINE}{ILSM_suffix} ne 'so' and
	$o->{INLINE}{ILSM_suffix} ne 'dll' and
	ref($o) eq 'Inline'
       ) {
	eval "require $o->{INLINE}{ILSM_module}";
	croak M05_error_eval('glue', $@) if $@;
	bless $o, $o->{INLINE}{ILSM_module};
    }

    $o->load;
}

#==============================================================================
# Get source from the DATA filehandle
#==============================================================================
my (%DATA, %DATA_read);
sub read_DATA {
    require Socket;
    my ($marker, $marker_tag);
    my $o = shift;
    my ($pkg, $language_id) = @{$o->{API}}{qw(pkg language_id)};
    unless ($DATA_read{$pkg}++) {
	no strict 'refs';
	*Inline::DATA = *{$pkg . '::DATA'};
	local ($/);
	my ($CR, $LF) = (&Socket::CR, &Socket::LF);
	(my $data = <Inline::DATA>) =~ s/$CR?$LF/\n/g;
	@{$DATA{$pkg}} = split /(?m)(__\S+?__\n)/, $data;
	shift @{$DATA{$pkg}} unless ($ {$DATA{$pkg}}[0] || '') =~ /__\S+?__\n/;
    }
    ($marker, $o->{API}{code}) = splice @{$DATA{$pkg}}, 0, 2;
    croak M08_no_DATA_source_code($language_id)
      unless defined $marker;
    ($marker_tag = $marker) =~ s/__(\S+?)__\n/$1/;
    croak M09_marker_mismatch($marker, $language_id)
      unless $marker_tag eq $language_id;
}

#==============================================================================
# Validate and store the non language-specific config options
#==============================================================================
sub check_config {
    my $o = shift;
    my @others;
    while (@_) {
	my ($key, $value) = (shift, shift);
	if (defined $default_config->{$key}) {
	    if ($key eq 'WITH') {
		croak M10_usage_WITH() if (ref $value and
					   ref $value ne 'ARRAY');
		$value = [$value] unless ref $value;
		$o->{CONFIG}{$key} = $value;
		next;
	    }
	    $o->{CONFIG}{$key} = $value, next if not $value;
	    if ($key eq 'DIRECTORY') {
		croak M11_usage_DIRECTORY($value) unless (-d $value);
		$value = abs_path($value);
	    }
	    elsif ($key eq 'NAME') {
		croak M12_usage_NAME($value) 
		  unless $value =~ /^[a-zA-Z_](\w|::)*$/;
	    }
	    elsif ($key eq 'VERSION') {
		croak M13_usage_VERSION($value) unless $value =~ /^\d\.\d\d*$/;
	    }
	    $o->{CONFIG}{$key} = $value;
	}
	else {
	    push @others, $key, $value;
	}
    }
    return (@others);
}

#==============================================================================
# Set option defaults based on current option settings.
#==============================================================================
sub fold_options {
    my $o = shift;
    $untaint = $o->{CONFIG}{UNTAINT} || 0;
    $safemode = (($o->{CONFIG}{SAFEMODE} == -1) ?
		 ($untaint ? 1 : 0) :
		 $o->{CONFIG}{SAFEMODE}
		);
    if (UNTAINT and
	SAFEMODE and
	not $o->{CONFIG}{DIRECTORY}) {
	croak M49_usage_unsafe(1) if ($< == 0 or $> == 0);
	warn M49_usage_unsafe(0) if $^W;
    }
    if ($o->{CONFIG}{AUTONAME} == -1) {
	$o->{CONFIG}{AUTONAME} = length($o->{CONFIG}{NAME}) ? 0 : 1;
    }
    $o->{API}{cleanup} = 
      ($o->{CONFIG}{CLEAN_AFTER_BUILD} and not $o->{CONFIG}{REPORTBUG});
}

#==============================================================================
# Check if Inline extension is preinstalled
#==============================================================================
sub check_installed {
    my $o = shift;
    $o->{INLINE}{object_ready} = 0;
    unless ($o->{API}{code} =~ /^[A-Fa-f0-9]{32}$/) {
	require Digest::MD5;
	$o->{INLINE}{md5} = Digest::MD5::md5_hex($o->{API}{code});
    }
    else {
	$o->{INLINE}{md5} = $o->{API}{code};
    }
    return if $o->{CONFIG}{_INSTALL_};
    return unless $o->{CONFIG}{VERSION};
    croak M26_error_version_without_name()
      unless $o->{CONFIG}{NAME};
    my $realname = $o->{API}{pkg};
    $realname =~ s|::|/|g;
    $realname .= '.pm';
    my $realpath = ($INC{$realname})
      or croak M27_module_not_indexed($realname);
    $realpath =~ s|^(.*)/\Q$realname\E$|$1|
      or croak M28_error_grokking_path($realpath);

    $o->{API}{version} = $o->{CONFIG}{VERSION};
    $o->{API}{module} = $o->{CONFIG}{NAME};
    my @modparts = split(/::/,$o->{API}{module});
    $o->{API}{modfname} = $modparts[-1];
    $o->{API}{modpname} = join('/',@modparts);
    $realpath =~ s|\bblib[/\\]lib$|blib/arch|;

    my $suffix = $Config{dlext};
    my $obj = "$realpath/auto/$o->{API}{modpname}/$o->{API}{modfname}.$suffix";
    croak M30_error_no_obj($o->{CONFIG}{NAME}, $o->{API}{pkg}, 
			   $realpath) unless -f $obj;

    @{$o->{CONFIG}}{qw( PRINT_INFO 
			REPORTBUG 
			FORCE_BUILD
			_INSTALL_
		      )} = (0, 0, 0, 0);

    $o->{install_lib} = $realpath;
    $o->{INLINE}{ILSM_type} = 'compiled';
    $o->{INLINE}{ILSM_module} = 'Inline::C';
    $o->{INLINE}{ILSM_suffix} = $suffix;
    $o->{INLINE}{object_ready} = 1;
}

#==============================================================================
# Dynamically load the object module
#==============================================================================
sub load {
    my $o = shift;

    if ($o->{CONFIG}{_INSTALL_}) {
	my $inline = "$o->{API}{modfname}.inl";
	open INLINE, "> $inline" 
	  or croak M24_open_for_output_failed($inline);
	print INLINE "*** AUTOGENERATED by Inline.pm ***\n\n";
	print INLINE "This file satisfies the make dependency for ";
	print INLINE "$o->{API}{modfname}.pm\n";
	close INLINE;
	return;
    }

    my ($pkg, $module) = @{$o->{API}}{qw(pkg module)};
    croak M42_usage_loader() unless $o->{INLINE}{ILSM_type} eq 'compiled';

    require DynaLoader;
    @Inline::ISA = qw(DynaLoader);

    my $global = $o->{CONFIG}{GLOBAL_LOAD} ? '0x01' : '0x00';
    my $version = $o->{API}{version} || '0.00';

    eval <<END;
	package $pkg;
	push \@$ {pkg}::ISA, qw($module)
          unless \$module eq "$pkg";
        local \$$ {module}::VERSION = '$version';

	package $module;
	push \@$ {module}::ISA, qw(Exporter DynaLoader);
        sub dl_load_flags { $global } 
	${module}::->bootstrap;
END
    croak M43_error_bootstrap($module, $@) if $@;
}

#==============================================================================
# Process the config options that apply to all Inline sections
#==============================================================================
sub handle_global_config {
    my $pkg = shift;
    while (@_) {
	my ($key, $value) = (shift, shift);
	croak M02_usage() if $key =~ /[\s\n]/;
	$key = $value if $key =~ /^(ENABLE|DISABLE)$/;
	croak M47_invalid_config_option($key)
	  unless defined $default_config->{$key};
	if ($key eq 'ENABLE') {
	    $CONFIG{$pkg}{template}{$value} = 1;
	}
	elsif ($key eq 'DISABLE') {
	    $CONFIG{$pkg}{template}{$value} = 0;
	}
	else {
	    $CONFIG{$pkg}{template}{$key} = $value;
	}
    }
}

#==============================================================================
# Process the config options that apply to a particular language
#==============================================================================
sub handle_language_config {
    my @values;
    while (@_) {
	my ($key, $value) = (shift, shift);
	croak M02_usage() if $key =~ /[\s\n]/;
	if ($key eq 'ENABLE') {
	    push @values, $value, 1;
	}
	elsif ($key eq 'DISABLE') {
	    push @values, $value, 0;
	}
	else {
	    push @values, $key, $value;
	}
    }
    return {@values};
}

#==============================================================================
# Validate and store shortcut config options
#==============================================================================
sub handle_shortcuts {
    my $pkg = shift;

    for my $option (@_) {
	my $OPTION = uc($option);
	if ($OPTION eq 'SITE_INSTALL') {
	    croak M58_site_install();
	}
	elsif ($shortcuts{$OPTION}) {
	    my ($method, $arg) = @{$shortcuts{$OPTION}};
	    $CONFIG{$pkg}{template}{$method} = $arg;
	}
	else {
	    croak M48_usage_shortcuts($option);
	}
    }    
}

#==============================================================================
# Process the with command
#==============================================================================
sub handle_with {
    my $pkg = shift;
    croak M45_usage_with() unless @_;
    for (@_) {
	croak M02_usage() unless /^[\w:]+$/;
	eval "require $_;";
	croak M46_usage_with_bad($_) . $@ if $@;
	push @{$CONFIG{$pkg}{template}{WITH}}, $_;
    }
}

#==============================================================================
# Perform cleanup duties
#==============================================================================
sub DESTROY {
    my $o = shift;
    $o->clean_build if $o->{CONFIG}{CLEAN_BUILD_AREA};
}

# Comment out the next 2 lines to stop autoloading of subroutines (testing)
#1;
#__END__

#==============================================================================
# Get the source code
#==============================================================================
sub receive_code {
    my $o = shift;
    my $code = shift;
    
    croak M02_usage() unless (defined $code and $code);

    if (ref $code eq 'CODE') {
	$o->{API}{code} = &$code;
    }
    elsif ($code =~ m|[/\\]| and
	   $code =~ m|^[\w/.-]+$|) {
	if (-f $code) {
	    local ($/, *CODE);
	    open CODE, "< $code" or croak M06_code_file_failed_open($code);
	    $o->{API}{code} = <CODE>;
	}
	else {
	    croak M07_code_file_does_not_exist($code);
	}
    } 
    elsif (ref $code eq 'ARRAY') {
	$o->{API}{code} = join '', @$code;
    }
    else {
	$o->{API}{code} = $code;
    }
}

#==============================================================================
# Get the source code from an Inline::Files filehandle
#==============================================================================
sub read_inline_file {
    my $o = shift;
    my ($lang, $pkg) = @{$o->{API}}{qw(language_id pkg)};
    my $langfile = uc($lang);
    croak M59_bad_inline_file($lang) unless $langfile =~ /^[A-Z]\w*$/;
    croak M60_no_inline_files() 
      unless (defined $INC{"Inline/Files.pm"} and
	      $Inline::Files::VERSION =~ /^\d\.\d\d$/ and
	      $Inline::Files::VERSION ge '0.51');
    croak M61_not_parsed() unless $lang = Inline::Files::get_filename($pkg);
    {
	no strict 'refs';
	local $/;
	$Inline::FILE = \*{"${pkg}::$langfile"};
#	open $Inline::FILE;
	$o->{API}{code} = <$Inline::FILE>;
#	close $Inline::FILE;
    }
}

#==============================================================================
# Read the cached config file from the Inline directory. This will indicate
# whether the Language code is valid or not.
#==============================================================================
sub check_config_file {
    my ($DIRECTORY, %config);
    my $o = shift;

    croak M14_usage_Config() if defined %main::Inline::Config::;
    croak M63_no_source($o->{API}{pkg}) 
      if $o->{INLINE}{md5} eq $o->{API}{code};

    # First make sure we have the DIRECTORY
    if ($o->{CONFIG}{_INSTALL_}) {
	croak M15_usage_install_directory()
	  if $o->{CONFIG}{DIRECTORY};
	my $cwd = Cwd::cwd();
	$DIRECTORY = $o->{INLINE}{DIRECTORY} = "$cwd/_Inline";
	if (not -d $DIRECTORY) {
	    _mkdir($DIRECTORY, 0777)
	      or croak M16_DIRECTORY_mkdir_failed($DIRECTORY);
	}
    }
    else {
	$DIRECTORY = $o->{INLINE}{DIRECTORY} =
	  $o->{CONFIG}{DIRECTORY} || $o->find_temp_dir;
    }

    $o->create_config_file($DIRECTORY) if not -e "$DIRECTORY/config";

    open CONFIG, "< $DIRECTORY/config"
      or croak M17_config_open_failed($DIRECTORY);
    my $config = join '', <CONFIG>;
    close CONFIG;

    croak M62_invalid_config_file("$DIRECTORY/config")
      unless $config =~ /^version :/;
    ($config) = $config =~ /(.*)/s if UNTAINT;

    %config = Inline::denter->new()->undent($config);
    $Inline::languages = $config{languages};

    croak M18_error_old_version($config{version}, $DIRECTORY)
	unless (defined $config{version} and
		$config{version} >= 0.40);
    croak M19_usage_language($o->{API}{language_id}, $DIRECTORY)
      unless defined $config{languages}->{$o->{API}{language_id}};
    $o->{API}{language} = $config{languages}->{$o->{API}{language_id}};
    if ($o->{API}{language} ne $o->{API}{language_id}) {
	if (defined $o->{$o->{API}{language_id}}) {
	    $o->{$o->{API}{language}} = $o->{$o->{API}{language_id}};
	    delete $o->{$o->{API}{language_id}};
	}
    }

    $o->{INLINE}{ILSM_type} = $config{types}->{$o->{API}{language}};
    $o->{INLINE}{ILSM_module} = $config{modules}->{$o->{API}{language}};
    $o->{INLINE}{ILSM_suffix} = $config{suffixes}->{$o->{API}{language}};
}

#==============================================================================
# Auto-detect installed Inline language support modules
#==============================================================================
sub create_config_file {
    my ($o, $dir) = @_;

    # This subroutine actually fires off another instance of perl.
    # with arguments that make this routine get called again.
    # That way the queried modules don't stay loaded.
    if (defined $o) {
	($dir) = $dir =~ /(.*)/s if UNTAINT;
	my $perl = $Config{perlpath};
	($perl) = $perl =~ /(.*)/s if UNTAINT;
	local $ENV{PERL5LIB} if defined $ENV{PERL5LIB};
	local $ENV{PERL5OPT} if defined $ENV{PERL5OPT};
	my $inline = $INC{'Inline.pm'};
	$inline =~ s|\\|/|g;
	$inline =~ s|/+|/|g;
	$inline =~ s|/?Inline\.pm||;
	$inline ||= '.';
	my $INC = "-I$inline -I" . join(" -I", grep {(-d "$_/Inline" or 
						      -d "$_/auto/Inline"
						     )} @INC);
	system "$perl $INC -MInline=_CONFIG_ -e1 $dir"
	  and croak M20_config_creation_failed($dir);
	return;
    }

    my ($lib, $mod, $register, %checked,
	%languages, %types, %modules, %suffixes);
  LIB:
    for my $lib (@INC) {
	next unless -d "$lib/Inline";
	opendir LIB, "$lib/Inline" 
	  or warn(M21_opendir_failed("$lib/Inline")), next;
	while ($mod = readdir(LIB)) {
	    next unless $mod =~ /\.pm$/;
	    $mod =~ s/\.pm$//;
	    next LIB if ($checked{$mod}++);
	    if ($mod eq 'Config') {     # Skip Inline::Config
		warn M14_usage_Config();
		next;
	    }
	    next if $mod =~ /^(devel|MakeMaker|denter|messages|Insh|Files)$/;
	    eval "require Inline::$mod;\$register=&Inline::${mod}::register";
	    if ($@) {
		warn "Warning: Had trouble with Inline::$mod: $@\n";
		next;
	    }
	    my $language = ($register->{language}) 
	      or warn(M22_usage_register($mod)), next;
	    for (@{$register->{aliases}}) {
		warn(M23_usage_alias_used($mod, $_, $languages{$_})), next
		  if defined $languages{$_};
		$languages{$_} = $language;
	    }
	    $languages{$language} = $language;
	    $types{$language} = $register->{type};
	    $modules{$language} = "Inline::$mod";
	    $suffixes{$language} = $register->{suffix};
	}
	closedir LIB;
    }

    my $file = "$ARGV[0]/config";
    open CONFIG, "> $file" or croak M24_open_for_output_failed($file);
    print CONFIG Inline::denter->new()
      ->indent(*version => $Inline::VERSION,
	       *languages => \%languages,
	       *types => \%types,
	       *modules => \%modules,
	       *suffixes => \%suffixes,
	      );
    close CONFIG;
    exit 0;
}

#==============================================================================
# Check to see if code has already been compiled
#==============================================================================
sub check_module {
    my ($module, $module2);
    my $o = shift;
    return $o->install if $o->{CONFIG}{_INSTALL_};

    if ($o->{CONFIG}{NAME}) {
	$module = $o->{CONFIG}{NAME};
    }
    elsif ($o->{API}{pkg} eq 'main') {
	$module = $o->{API}{script};
	$module =~ s|^.*[/\\](.*)$|$1|;
	$module =~ s|\W|_|g;
	$module =~ s|^_+||;
	$module =~ s|_+$||;
	$module = 'FOO' if $module =~ /^_*$/;
	$module = "_$module" if $module =~ /^\d/;
    }
    else {
	$module = $o->{API}{pkg};
    }

    $o->{API}{suffix} = $o->{INLINE}{ILSM_suffix};
    $o->{API}{directory} = $o->{INLINE}{DIRECTORY};

    my $auto_level = 2;
    while ($auto_level <= 5) {
	if ($o->{CONFIG}{AUTONAME}) {
	    $module2 = 
	      $module . '_' . substr($o->{INLINE}{md5}, 0, 2**$auto_level);
	    $auto_level++;
	} else {
	    $module2 = $module;
	    $auto_level = 6; # Don't loop on non-autoname objects
	}
	$o->{API}{module} = $module2;
	my @modparts = split /::/, $module2;
	$o->{API}{modfname} = $modparts[-1];
	$o->{API}{modpname} = join('/',@modparts);
	$o->{API}{build_dir} = 
	  $o->{INLINE}{DIRECTORY} . '/build/' . $o->{API}{modpname};
	$o->{API}{install_lib} = $o->{INLINE}{DIRECTORY} . '/lib';

	my $inl = "$o->{API}{install_lib}/auto/" .
	  "$o->{API}{modpname}/$o->{API}{modfname}.inl";
	$o->{API}{location} = "$o->{API}{install_lib}/auto/" .
	  "$o->{API}{modpname}/$o->{API}{modfname}.$o->{INLINE}{ILSM_suffix}";
	last unless -f $inl;
	my %inl;
	{   local ($/, *INL);
	    open INL, $inl or croak M31_inline_open_failed($inl);
	    %inl = Inline::denter->new()->undent(<INL>);
	}
	next unless ($o->{INLINE}{md5} eq $inl{md5});
	next unless ($inl{inline_version} ge '0.40');
	unless (-f $o->{API}{location}) {
	    warn <<END if $^W;
Missing object file: $o->{API}{location}
For Inline file: $inl
END
	    next;
	}
	$o->{INLINE}{object_ready} = 1 unless $o->{CONFIG}{FORCE_BUILD};
	last;
    }
    unshift @::INC, $o->{API}{install_lib};
}

#==============================================================================
# Set things up so that the extension gets installed into the blib/arch.
# Then 'make install' will do the right thing.
#==============================================================================
sub install {
    my ($module, $DIRECTORY);
    my $o = shift;

    croak M64_install_not_c($o->{API}{language_id})
      unless uc($o->{API}{language_id}) eq 'C';
    croak M36_usage_install_main()
      if ($o->{API}{pkg} eq 'main');
    croak M37_usage_install_auto()
      if $o->{CONFIG}{AUTONAME};
    croak M38_usage_install_name()
      unless $o->{CONFIG}{NAME};
    croak M39_usage_install_version()
      unless $o->{CONFIG}{VERSION};
    croak M40_usage_install_badname($o->{CONFIG}{NAME}, $o->{API}{pkg})
      unless $o->{CONFIG}{NAME} eq $o->{API}{pkg};
#	      $o->{CONFIG}{NAME} =~ /^$o->{API}{pkg}::\w(\w|::)+$/
#	     );

    my ($mod_name, $mod_ver, $ext_name, $ext_ver) = 
      ($o->{API}{pkg}, $ARGV[0], @{$o->{CONFIG}}{qw(NAME VERSION)});
    croak M41_usage_install_version_mismatch($mod_name, $mod_ver, 
					     $ext_name, $ext_ver)
      unless ($mod_ver eq $ext_ver);
    $o->{INLINE}{INST_ARCHLIB} = $ARGV[1];

    $o->{API}{version} = $o->{CONFIG}{VERSION};
    $o->{API}{module} = $o->{CONFIG}{NAME};
    my @modparts = split(/::/,$o->{API}{module});
    $o->{API}{modfname} = $modparts[-1];
    $o->{API}{modpname} = join('/',@modparts);
    $o->{API}{suffix} = $o->{INLINE}{ILSM_suffix};
    $o->{API}{build_dir} = ( $o->{INLINE}{DIRECTORY} . '/build/' . 
			     $o->{API}{modpname}
			   );
    $o->{API}{directory} = $o->{INLINE}{DIRECTORY};
    my $cwd = Cwd::cwd();
    $o->{API}{install_lib} = "$cwd/$o->{INLINE}{INST_ARCHLIB}";
    $o->{API}{location} = "$o->{API}{install_lib}/auto/" .
      "$o->{API}{modpname}/$o->{API}{modfname}.$o->{INLINE}{ILSM_suffix}";
    unshift @::INC, $o->{API}{install_lib};
    $o->{INLINE}{object_ready} = 0;
}

#==============================================================================
# Create the .inl file for an object
#==============================================================================
sub write_inl_file {
    my $o = shift;
    my $inl = "$o->{API}{install_lib}/auto/$o->{API}{modpname}/$o->{API}{modfname}.inl";
    open INL, "> $inl"
      or die "Can't create Inline validation file $inl";
    my $apiversion = $Config{apiversion} || $Config{xs_apiversion};
    print INL Inline::denter->new()
      ->indent(*md5, $o->{INLINE}{md5},
	       *name, $o->{API}{module},
	       *version, $o->{CONFIG}{VERSION},
	       *language, $o->{API}{language},
	       *language_id, $o->{API}{language_id},
	       *installed, $o->{CONFIG}{_INSTALL_},
	       *date_compiled, scalar localtime,
	       *inline_version, $Inline::VERSION,
	       *ILSM, { map {($_, $o->{INLINE}{"ILSM_$_"})}
			(qw( module suffix type ))
		      },
	       *Config, { (map {($_,$Config{$_})}
			   (qw( archname osname osvers
				cc ccflags ld so version
			      ))), 
			  (apiversion => $apiversion),
			},
	      );
    close INL;
}

#==============================================================================
# Get config hints
#==============================================================================
sub with_configs {
    my $o = shift;
    my @configs;
    for my $mod (@{$o->{CONFIG}{WITH}}) {
	my $ref = eval {
	    no strict 'refs';
	    &{$mod . "::Inline"}($o->{API}{language});
	};
	croak M25_no_WITH_support($mod, $@) if $@;
	push @configs, %$ref;
    }
    return @configs;
}

#==============================================================================
# Blindly untaint tainted fields in Inline object.
#==============================================================================
sub env_untaint {
    my $o = shift;

    for (keys %ENV) {
	($ENV{$_}) = $ENV{$_} =~ /(.*)/;
    }
    my $delim = $^O eq 'MSWin32' ? ';' : ':';
    $ENV{PATH} = join $delim, grep {not /^\./ and
				      not ((stat($_))[2] & 0022)
				  } split $delim, $ENV{PATH};
    map {($_) = /(.*)/} @INC;
}
#==============================================================================
# Blindly untaint tainted fields in Inline object.
#==============================================================================
sub obj_untaint {
    my $o = shift;

    ($o->{INLINE}{ILSM_module}) = $o->{INLINE}{ILSM_module} =~ /(.*)/;
    ($o->{API}{build_dir}) = $o->{API}{build_dir} =~ /(.*)/;
    ($o->{CONFIG}{DIRECTORY}) = $o->{CONFIG}{DIRECTORY} =~ /(.*)/;
    ($o->{API}{install_lib}) = $o->{API}{install_lib} =~ /(.*)/;
    ($o->{API}{modpname}) = $o->{API}{modpname} =~ /(.*)/;
    ($o->{API}{modfname}) = $o->{API}{modfname} =~ /(.*)/;
    ($o->{API}{language}) = $o->{API}{language} =~ /(.*)/;
    ($o->{API}{pkg}) = $o->{API}{pkg} =~ /(.*)/;
    ($o->{API}{module}) = $o->{API}{module} =~ /(.*)/;
}

#==============================================================================
# Clean the build directory from previous builds
#==============================================================================
sub clean_build {
    use strict;
    my ($prefix, $dir);
    my $o = shift;

    $prefix = $o->{INLINE}{DIRECTORY};
    opendir(BUILD, $prefix)
      or die "Can't open build directory: $prefix for cleanup $!\n";

    while ($dir = readdir(BUILD)) {
	if ((-d "$prefix$dir") and ($dir =~ /\w{36,}/)) {
	    $o->rmpath($prefix, $dir); 
	}
    }

    close BUILD;
}

#==============================================================================
# Apply a list of filters to the source code
#==============================================================================
sub filter {
    my $o = shift;
    my $new_code = $o->{API}{code};
    for (@_) {
	croak M52_invalid_filter($_) unless ref;
	if (ref eq 'CODE') {
	    $new_code = $_->($new_code);
	}
	else {
	    $new_code = $_->filter($o, $new_code);
	}
    }
    return $new_code;
}

#==============================================================================
# User wants to report a bug
#==============================================================================
sub reportbug {
    use strict;
    my $o = shift;
    return if $o->{INLINE}{reportbug_handled}++;
    print STDERR <<END;
<-----------------------REPORTBUG Section------------------------------------->

REPORTBUG mode in effect.

Your Inline $o->{API}{language_id} code will be processed in the build directory:

  $o->{API}{build_dir}

A perl-readable bug report including your perl configuration and run-time
diagnostics will also be generated in the build directory.

When the program finishes please bundle up the above build directory with:

  tar czf Inline.REPORTBUG.tar.gz $o->{API}{build_dir}

and send "Inline.REPORTBUG.tar.gz" as an email attachment to the author
of the offending Inline::* module with the subject line:

  REPORTBUG: Inline.pm

Include in the email, a description of the problem and anything else that
you think might be helpful. Patches are welcome! :-\)

<-----------------------End of REPORTBUG Section------------------------------>
END
    my %versions;
    {
	no strict 'refs';
	%versions = map {eval "use $_();"; ($_, $ {$_ . '::VERSION'})}
	qw (Digest::MD5 Parse::RecDescent 
	    ExtUtils::MakeMaker File::Path FindBin 
	    Inline
	   );
    }

    $o->mkpath($o->{API}{build_dir});
    open REPORTBUG, "> $o->{API}{build_dir}/REPORTBUG"
      or croak M24_open_for_output_failed("$o->{API}{build_dir}/REPORTBUG");
    %Inline::REPORTBUG_Inline_Object = ();
    %Inline::REPORTBUG_Perl_Config = ();
    %Inline::REPORTBUG_Module_Versions = ();
    print REPORTBUG Inline::denter->new()
      ->indent(*REPORTBUG_Inline_Object, $o, 
	       *REPORTBUG_Perl_Config, \%Config::Config,
	       *REPORTBUG_Module_Versions, \%versions,
	      );
    close REPORTBUG;
}

#==============================================================================
# Print a small report if PRINT_INFO option is set.
#==============================================================================
sub print_info {
    use strict;
    my $o = shift;

    print STDERR <<END;
<-----------------------Information Section----------------------------------->

Information about the processing of your Inline $o->{API}{language_id} code:

END
    
    print STDERR <<END if ($o->{INLINE}{object_ready});
Your module is already compiled. It is located at:
$o->{API}{location}

END

    print STDERR <<END if ($o->{INLINE}{object_ready} and $o->{CONFIG}{FORCE_BUILD});
But the FORCE_BUILD option is set, so your code will be recompiled.
I\'ll use this build directory:
$o->{API}{build_dir}

and I\'ll install the executable as:
$o->{API}{location}

END
    print STDERR <<END if (not $o->{INLINE}{object_ready});
Your source code needs to be compiled. I\'ll use this build directory:
$o->{API}{build_dir}

and I\'ll install the executable as:
$o->{API}{location}

END
    
    eval {
	print STDERR $o->info;
    };
    print $@ if $@;

    print STDERR <<END;

<-----------------------End of Information Section---------------------------->
END
}

#==============================================================================
# Hand off this invokation to Inline::MakeMaker
#==============================================================================
sub maker_utils {
    require Inline::MakeMaker;
    goto &Inline::MakeMaker::utils;
}

#==============================================================================
# Utility subroutines
#==============================================================================

#==============================================================================
# Make a path
#==============================================================================
sub mkpath {
    use strict;
    my ($o, $mkpath) = @_;
    my @parts = grep {$_} split(/\//,$mkpath);
    my $path = ($parts[0] =~ /^[A-Za-z]:$/)
      ? shift(@parts) . '/'  #MSWin32 Drive Letter (ie C:)
	: '/';
    foreach (@parts){
	-d "$path$_" || _mkdir("$path$_", 0777);
	$path .= "$_/";
    }
    croak M53_mkdir_failed($mkpath)
      unless -d $mkpath;
}

#==============================================================================
# Nuke a path (nicely)
#==============================================================================
sub rmpath {
    use strict;
    my ($o, $prefix, $rmpath) = @_;
# Nuke the target directory
    _rmtree("$prefix$rmpath");
# Remove any empty directories underneath the requested one
    my @parts = grep {$_} split(/\//,$rmpath);
    pop @parts;
    while (@parts){
	$rmpath = join '/', @parts;
	rmdir "$prefix$rmpath"
	  or last; # rmdir failed because dir was not empty
	pop @parts;
    }
}

sub _rmtree {
    my($roots) = @_;
    my(@files);
    $roots = [$roots] unless ref $roots;
    my($root);
    foreach $root (@{$roots}) {
        $root =~ s#/\z##;
        if ( -d $root ) {
            if (opendir MYDIR, $root) {
                @files = readdir MYDIR;
                closedir MYDIR;
            }
            else {
                croak M21_opendir_failed($root);
            }

            @files = map("$root/$_", grep $_!~/^\.{1,2}\z/s,@files);
            _rmtree(\@files);
	    ($root) = $root =~ /(.*)/ if UNTAINT;
            rmdir($root) or croak M54_rmdir_failed($root);
        }
        else { 
	    ($root) = $root =~ /(.*)/ if UNTAINT;
	    unlink($root) or croak M55_unlink_failed($root);
        }
    }
}

#==============================================================================
# Find the 'Inline' directory to use.
#==============================================================================
my $TEMP_DIR;
sub find_temp_dir {
    return $TEMP_DIR if $TEMP_DIR;
    
    my ($temp_dir, $home, $bin, $cwd, $env);
    $temp_dir = '';
    $env = $ENV{PERL_INLINE_DIRECTORY} || '';
    $home = $ENV{HOME} ? abs_path($ENV{HOME}) : '';
    
    if ($env and
	-d $env and
	-w $env) {
	$temp_dir = $env;
    }
    elsif ($cwd = abs_path('.') and
	   $cwd ne $home and
	   -d "$cwd/.Inline/" and
	   -w "$cwd/.Inline/") {
	$temp_dir = "$cwd/.Inline";
    }
    elsif (require FindBin and
           $bin = $FindBin::Bin and
	   -d "$bin/.Inline/" and
	   -w "$bin/.Inline/") {
	$temp_dir = "$bin/.Inline";
    } 
    elsif ($home and
	   -d "$home/.Inline/" and
	   -w "$home/.Inline/") {
	$temp_dir = "$home/.Inline";
    } 
    elsif (defined $cwd and $cwd and
	   -d "$cwd/_Inline/" and
	   -w "$cwd/_Inline/") {
	$temp_dir = "$cwd/_Inline";
    }
    elsif (defined $bin and $bin and
	   -d "$bin/_Inline/" and
	   -w "$bin/_Inline/") {
	$temp_dir = "$bin/_Inline";
    } 
    elsif (defined $cwd and $cwd and
	   -d $cwd and
	   -w $cwd and
	   _mkdir("$cwd/_Inline", 0777)) {
	$temp_dir = "$cwd/_Inline";
    }
    elsif (defined $bin and $bin and
	   -d $bin and
	   -w $bin and
	   _mkdir("$bin/_Inline", 0777)) {
	$temp_dir = "$bin/_Inline";
    }

    croak M56_no_DIRECTORY_found()
      unless $temp_dir;
    return $TEMP_DIR = abs_path($temp_dir);
}

sub _mkdir {
    my $dir = shift;
    my $mode = shift || 0777;
    ($dir) = ($dir =~ /(.*)/) if UNTAINT;
    $dir =~ s|[/\\]$||;
    return mkdir($dir, $mode);
}

# Comment out the next 2 lines to stop autoloading of messages (for testing)
#1;
#__END__

#==============================================================================
# Error messages are autoloaded
#==============================================================================

sub M01_usage_use {
    my ($module) = @_;
    return <<END;
It is invalid to use '$module' directly. Please consult the Inline 
documentation for more information.

END
}

sub M02_usage {
    my $usage = <<END;
Invalid usage of Inline module. Valid usages are:
    use Inline;
    use Inline language => "source-string", config-pair-list;
    use Inline language => "source-file", config-pair-list;
    use Inline language => [source-line-list], config-pair-list;
    use Inline language => 'DATA', config-pair-list;
    use Inline language => 'Config', config-pair-list;
    use Inline Config => config-pair-list;
    use Inline with => module-list;
    use Inline shortcut-list;
END
# This is broken ????????????????????????????????????????????????????
    $usage .= <<END if defined $Inline::languages;

Supported languages:
    ${\ join(', ', sort keys %$Inline::languages)}

END
    return $usage;
}

sub M03_usage_bind {
    my $usage = <<END;
Invalid usage of the Inline->bind() function. Valid usages are:
    Inline->bind(language => "source-string", config-pair-list);
    Inline->bind(language => "source-file", config-pair-list);
    Inline->bind(language => [source-line-list], config-pair-list);
END

    $usage .= <<END if defined $Inline::languages;

Supported languages:
    ${\ join(', ', sort keys %$Inline::languages)}

END
    return $usage;
}

sub M04_error_nocode {
    my ($language) = @_;
    return <<END;
No $language source code found for Inline.

END
}

sub M05_error_eval {
    my ($subroutine, $msg) = @_;
    return <<END;
An eval() failed in Inline::$subroutine:
$msg

END
}

sub M06_code_file_failed_open {
    my ($file) = @_;
    return <<END;
Couldn't open Inline code file '$file':
$!

END
#'
}

sub M07_code_file_does_not_exist {
    my ($file) = @_;
    return <<END;
Inline assumes '$file' is a filename, 
and that file does not exist.

END
}

sub M08_no_DATA_source_code {
    my ($lang) = @_;
    return <<END;
No source code in DATA section for Inline '$lang' section.

END
}

sub M09_marker_mismatch {
    my ($marker, $lang) = @_;
    return <<END;
Marker '$marker' does not match Inline '$lang' section.

END
}

sub M10_usage_WITH {
    return <<END;
Config option WITH must be a module name or an array ref of module names.

END
}

sub M11_usage_DIRECTORY {
    my ($value) = @_;
    return <<END;
Invalid value '$value' for config option DIRECTORY

END
}

sub M12_usage_NAME {
    my ($name) = @_;
    return <<END;
Invalid value for NAME config option: '$name'

END
}

sub M13_usage_VERSION {
    my ($version) = @_;
    return <<END;
Invalid value for VERSION config option: '$version'
Must be of the form '#.##'. 
(Should also be specified as a string rather than a floating point number)

END
}

sub M14_usage_Config {
    return <<END;
As of Inline v0.30, use of the Inline::Config module is no longer supported
or allowed. If Inline::Config exists on your system, it can be removed. See
the Inline documentation for information on how to configure Inline.
(You should find it much more straightforward than Inline::Config :-)

END
}

sub M15_usage_install_directory {
    return <<END;
Can't use the DIRECTORY option when installing an Inline extension module.

END
#'
}

sub M16_DIRECTORY_mkdir_failed {
    my ($dir) = @_;
    return <<END;
Can't mkdir $dir to build Inline code.

END
#'
}

sub M17_config_open_failed {
    my ($dir) = @_;
    return <<END;
Can't open ${dir}/config for input.

END
#'
}

sub M18_error_old_version {
    my ($old_version, $directory) = @_;
    $old_version ||= '???';
    return <<END;
You are using Inline version $Inline::VERSION with a directory that was 
configured by Inline version $old_version. This version is no longer supported.
Please delete the following directory and try again:

    $directory

END
}

sub M19_usage_language {
    my ($language, $directory) = @_;
    return <<END;
Error. You have specified '$language' as an Inline programming language.

I currently only know about the following languages:
    ${ defined $Inline::languages ? 
       \ join(', ', sort keys %$Inline::languages) : \ ''
     }

If you have installed a support module for this language, try deleting the
config file from the following Inline DIRECTORY, and run again:

    $directory

END
}

sub M20_config_creation_failed {
    my ($dir) = @_;
    return <<END;
Failed to autogenerate ${dir}/config.

END
}

sub M21_opendir_failed {
    my ($dir) = @_;
    return <<END;
Can't open directory '$dir'.

END
#'
}

sub M22_usage_register {
    my ($language, $error) = @_;
    return <<END;
The module Inline::$language does not support the Inline API, because it does
properly support the register() method. This module will not work with Inline
and should be uninstalled from your system. Please advise your sysadmin.

The following error was generating from this module:
$error

END
}

sub M23_usage_alias_used {
    my ($new_mod, $alias, $old_mod) = @_;
    return <<END;
The module Inline::$new_mod is attempting to define $alias as an alias.
But $alias is also an alias for Inline::$old_mod.

One of these modules needs to be corrected or removed.
Please notify the system administrator.

END
}

sub M24_open_for_output_failed {
    my ($file) = @_;
    return <<END;
Can't open $file for output.
$!

END
#'
}

sub M25_no_WITH_support {
    my ($mod, $err) = @_;
    return <<END;
You have requested "use Inline with => '$mod'"
but '$mod' does not work with Inline.

$err

END
}

sub M26_error_version_without_name {
    return <<END;
Specifying VERSION option without NAME option is not permitted.

END
}

sub M27_module_not_indexed {
    my ($mod) = @_;
    return <<END;
You are attempting to load an extension for '$mod',
but there is no entry for that module in %INC.

END
}

sub M28_error_grokking_path {
    my ($path) = @_;
    return <<END;
Can't calculate a path from '$path' in %INC

END
}

sub M29_error_relative_path {
    my ($name, $path) = @_;
    return <<END;
Can't load installed extension '$name'
from relative path '$path'.

END
#'
}

sub M30_error_no_obj {
    my ($name, $pkg, $path) = @_;
    <<END;
The extension '$name' is not properly installed in path:
  '$path'

If this is a CPAN/distributed module, you may need to reinstall it on your
system.

To allow Inline to compile the module in a temporary cache, simply remove the
Inline config option 'VERSION=' from the $pkg module.

END
}

sub M31_inline_open_failed {
    my ($file) = @_;
    return <<END;
Can't open Inline validate file: 

    $file

$!

END
#'
}

sub M32_error_md5_validation {
    my ($md5, $inl) = @_;
    return <<END;
The source code fingerprint:

    $md5

does not match the one in:

    $inl

This module needs to be reinstalled.

END
}

sub M33_error_old_inline_version {
    my ($inl) = @_;
    return <<END;
The following extension is not compatible with this version of Inline.pm.

    $inl

You need to reinstall this extension.

END
}

sub M34_error_incorrect_version {
    my ($inl) = @_;
    return <<END;
The version of your extension does not match the one indicated by your
Inline source code, according to:

    $inl

This module should be reinstalled.

END
}

sub M35_error_no_object_file {
    my ($obj, $inl) = @_;
    return <<END;
There is no object file:
    $obj

For Inline validation file:
    $inl

This module should be reinstalled.

END
}

sub M36_usage_install_main {
    return <<END;
Can't install an Inline extension module from package 'main'.

END
#'
}

sub M37_usage_install_auto {
    return <<END;
Can't install an Inline extension module with AUTONAME enabled.

END
#'
}

sub M38_usage_install_name {
    return <<END;
An Inline extension module requires an explicit NAME.

END
}

sub M39_usage_install_version {
    return <<END;
An Inline extension module requires an explicit VERSION.

END
}

sub M40_usage_install_badname {
    my ($name, $pkg) = @_;
    return <<END;
The NAME '$name' is illegal for this Inline extension.
The NAME must match the current package name:
    $pkg

END
}

sub M41_usage_install_version_mismatch {
    my ($mod_name, $mod_ver, $ext_name, $ext_ver) = @_;
    <<END;
The version '$mod_ver' for module '$mod_name' doe not match
the version '$ext_ver' for Inline section '$ext_name'.

END
}

sub M42_usage_loader {
    return <<END;
ERROR. The loader that was invoked is for compiled languages only.

END
}

sub M43_error_bootstrap {
    my ($mod, $err) = @_;
    return <<END;
Had problems bootstrapping Inline module '$mod'

$err

END
}

sub M45_usage_with {
    return <<END;
Syntax error detected using 'use Inline with ...'.
Should be specified as:

    use Inline with => 'module1', 'module2', ..., 'moduleN';

END
}

sub M46_usage_with_bad {
    my $mod = shift;
    return <<END;
Syntax error detected using 'use Inline with => "$mod";'.
'$mod' could not be found.

END
}

sub M47_invalid_config_option {
    my ($option) = @_;
    return <<END;
Invalid Config option '$option'

END
#'
}

sub M48_usage_shortcuts {
    my ($shortcut) = @_;
    return <<END;
Invalid shortcut '$shortcut' specified.

Valid shortcuts are:
    VERSION, INFO, FORCE, NOCLEAN, CLEAN, UNTAINT, SAFE, UNSAFE, 
    GLOBAL and REPORTBUG

END
}

sub M49_usage_unsafe {
    my ($terminate) = @_;
    return <<END .
You are using the Inline.pm module with the UNTAINT and SAFEMODE options,
but without specifying the DIRECTORY option. This is potentially unsafe.
Either use the DIRECTORY option or turn off SAFEMODE.

END
      ($terminate ? <<END : "");
Since you are running as the a privledged user, Inline.pm is terminating.

END
}

sub M51_unused_DATA {
    return <<END;
One or more DATA sections were not processed by Inline.

END
}

sub M52_invalid_filter {
    my ($filter) = @_;
    return <<END;
Invalid filter '$filter' is not a reference.

END
}

sub M53_mkdir_failed {
    my ($dir) = @_;
    return <<END;
Couldn't make directory path '$dir'.

END
#'
}

sub M54_rmdir_failed {
    my ($dir) = @_;
    return <<END;
Can't remove directory '$dir': 

$!

END
#'
}

sub M55_unlink_failed {
    my ($file) = @_;
    return <<END;
Can't unlink file '$file': 

$!

END
#'
}

sub M56_no_DIRECTORY_found {
    return <<END;
Couldn't find an appropriate DIRECTORY for Inline to use.

END
#'
}

sub M57_wrong_architecture {
    my ($ext, $arch, $thisarch) = @_;
    return <<END;
The extension '$ext'
is built for perl on the '$arch' platform.
This is the '$thisarch' platform.

END
}

sub M58_site_install {
    return <<END;
You have specified the SITE_INSTALL command. Support for this option has 
been removed from Inline since version 0.40. It has been replaced by the
use of Inline::MakeMaker in your Makefile.PL. Please see the Inline
documentation for more help on creating and installing Inline based modules.

END
}

sub M59_bad_inline_file {
    my ($lang) = @_;
    return <<END;
Could not find any Inline source code for the '$lang' language using 
the Inline::Files module.

END
}

sub M60_no_inline_files {
    return <<END;
It appears that you have requested to use Inline with Inline::Files.
You need to explicitly 'use Inline::Files;' before your 'use Inline'.

END
}

sub M61_not_parsed {
    return <<END;
It does not appear that your program has been properly parsed by Inline::Files.

END
}

sub M62_invalid_config_file {
    my ($config) = @_;
    return <<END;
You are using a config file that was created by an older version of Inline:

    $config

This file and all the other components in its directory are no longer valid
for this version of Inline. The best thing to do is simply delete all the 
contents of the directory and let Inline rebuild everything for you. Inline 
will do this automatically when you run your programs.

END
}

sub M63_no_source {
    my ($pkg) = @_;
    return <<END;
This module $pkg can not be loaded and has no source code.
You may need to reinstall this module.

END
}

sub M64_install_not_c {
    my ($lang) = @_;
    return <<END;
Invalid attempt to install an Inline module using the '$lang' language.

Only C based modules are currently supported.

END
}

1;
__END__