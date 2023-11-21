package PandoraFMS::SNMPServer;
##########################################################################
# Pandora FMS SNMP Console.
# Pandora FMS. the Flexible Monitoring System. http://www.pandorafms.org
##########################################################################
# Copyright (c) 2005-2023 Pandora FMS
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public License
# as published by the Free Software Foundation; version 2
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
##########################################################################

use strict;
use warnings;

use threads;
use threads::shared;
use Thread::Semaphore;

use Time::Local;
use Time::HiRes qw(usleep);
use XML::Simple;

use Scalar::Util qw(looks_like_number);

# Default lib dir for RPM and DEB packages
BEGIN { push @INC, '/usr/lib/perl5'; }

use PandoraFMS::Tools;
use PandoraFMS::DB;
use PandoraFMS::Core;
use PandoraFMS::ProducerConsumerServer;

# Inherits from PandoraFMS::ProducerConsumerServer
our @ISA = qw(PandoraFMS::ProducerConsumerServer);
our @EXPORT = qw(start_snmptrapd);

# Global variables
my @TaskQueue :shared;
my %PendingTasks :shared;
my $Sem :shared;
my %Sources :shared;
my $SourceSem :shared;
my $TaskSem :shared;

# Trap statistics by agent
my %AGENTS = ();

# Sources silenced by storm protection.
my %SILENCEDSOURCES = ();

# Index and buffer management for trap log files
my $SNMPTRAPD  = { 'log_file' => '', 'fd' => undef, 'idx_file' => '', 'last_line' => 0, 'last_size' => 0, 'read_ahead_line' => '', 'read_ahead_pos' => 0 };
my $DATASERVER = { 'log_file' => '', 'fd' => undef, 'idx_file' => '', 'last_line' => 0, 'last_size' => 0, 'read_ahead_line' => '', 'read_ahead_pos' => 0 };
my $BUFFER     = { 'log_file' => undef, 'fd' => [], 'idx_file' => undef, 'last_line' => 0, 'last_size' => 0, 'read_ahead_line' => undef, 'read_ahead_pos' => 0 };

########################################################################################
# SNMP Server class constructor.
########################################################################################
sub new ($$$) {
	my ($class, $config, $dbh) = @_;

	return undef unless $config->{'snmpconsole'} == 1;

	# Start snmptrapd
	if (start_snmptrapd ($config) != 0) {
		return undef;
	}
	
	# Wait for the SNMP log file to be available
	$SNMPTRAPD->{'log_file'} = $config->{'snmp_logfile'};
	sleep ($config->{'server_threshold'}) if (! -e $SNMPTRAPD->{'log_file'});
	if (!open ($SNMPTRAPD->{'fd'}, $SNMPTRAPD->{'log_file'})) {
		logger ($config, ' [E] Could not open the SNMP log file ' . $SNMPTRAPD->{'log_file'} . ".", 1);
		print_message ($config, ' [E] Could not open the SNMP log file ' . $SNMPTRAPD->{'log_file'} . ".", 1);
		return 1;
	}
	init_log_file($config, $SNMPTRAPD);

	# Create the Data Server SNMP log file if it does not exist.
	if (defined($config->{'snmp_extlog'}) && $config->{'snmp_extlog'} ne '') {
		$DATASERVER->{'log_file'} = $config->{'snmp_extlog'};
		open(TMPFD, '>', $DATASERVER->{'log_file'}) && close(TMPFD) if (! -e $DATASERVER->{'log_file'});
		if (!open ($DATASERVER->{'fd'}, $DATASERVER->{'log_file'})) {
			logger ($config, ' [E] Could not open the Data Server SNMP log file ' . $DATASERVER->{'log_file'} . ".", 1);
			print_message ($config, ' [E] Could not open the Data Server SNMP log file ' . $DATASERVER->{'log_file'} . ".", 1);
			return 1;
		}
		init_log_file($config, $DATASERVER);
	}

	# Initialize semaphores and queues
	@TaskQueue = ();
	%PendingTasks = ();
	$Sem = Thread::Semaphore->new;
	$TaskSem = Thread::Semaphore->new (0);
	$SourceSem = Thread::Semaphore->new (1);

	# Call the constructor of the parent class
	my $self = $class->SUPER::new($config, SNMPCONSOLE, \&PandoraFMS::SNMPServer::data_producer, \&PandoraFMS::SNMPServer::data_consumer, $dbh);

	# Save the path of snmptrapd
	$self->{'snmp_trapd'} = $config->{'snmp_trapd'};

    bless $self, $class;
    return $self;
}

###############################################################################
# Run.
###############################################################################
sub run ($) {
	my $self = shift;
	my $pa_config = $self->getConfig ();

	print_message ($pa_config, " [*] Starting " . $pa_config->{'rb_product_name'} . " SNMP Console.", 2);
	
	# Set the initial date for storm protection.
	$pa_config->{"__storm_ref__"} = time();

	# Set a server-specific period.
	if ($pa_config->{'snmpconsole_threshold'} > 0) {
		$self->setPeriod($pa_config->{'snmpconsole_threshold'});
	}

	$self->setNumThreads ($pa_config->{'snmpconsole_threads'});
	$self->SUPER::run (\@TaskQueue, \%PendingTasks, $Sem, $TaskSem);
}

###############################################################################
# Data producer.
###############################################################################
sub data_producer ($) {
	my $self = shift;
	my ($pa_config, $dbh) = ($self->getConfig (), $self->getDBH ());

	my %tasks_by_source;
	my @tasks;
	my @buffer;
	
	# Reset storm protection counters
	my $curr_time = time ();
	if ($pa_config->{"__storm_ref__"} + $pa_config->{"snmp_storm_timeout"} < $curr_time
		|| $pa_config->{'snmpconsole_lock'} == 1
	) {
		$pa_config->{"__storm_ref__"} = $curr_time;
		%AGENTS = ();
	}

	# Make a local copy of locked sources.
	$SourceSem->down ();
	my $local_sources = {%Sources};
	$SourceSem->up ();

	for my $fs (($BUFFER, $SNMPTRAPD, $DATASERVER)) {
		next unless defined($fs->{'fd'});
		reset_if_truncated($pa_config, $fs);
		while (my $line_with_pos = read_snmplogfile($fs)) {
			my $line;
	
			$fs->{'last_line'}++;
			($fs->{'last_size'}, $line) = @$line_with_pos;
	
			chomp ($line);
	
			# Update index file
			if (defined($fs->{'idx_file'})) {
				open(my $idxfd, '>' . $fs->{'idx_file'});
				print $idxfd $fs->{'last_line'} . ' ' . $fs->{'last_size'};
				close $idxfd;
			}
	
			# Skip lines other than SNMP Trap logs
			next unless ($line =~ m/^SNMPv[12]\[\*\*\]/);
	
			# Storm protection.
			my ($ver, $date, $time, $source, $null) = split(/\[\*\*\]/, $line, 5);
			if ($ver eq "SNMPv2" || $pa_config->{'snmp_pdu_address'} eq '1' ) {
				$source =~ s/(?:(?:TCP|UDP):\s*)?\[?([^] ]+)\]?(?::-?\d+)?(?:\s*->.*)?$/$1/;
			}

			next unless defined ($source);
			if (! defined ($AGENTS{$source})) {
				$AGENTS{$source}{'count'} = 1;
				$AGENTS{$source}{'event'} = 0;
				if (! defined ($SILENCEDSOURCES{$source})) {
					$SILENCEDSOURCES{$source} = 0;
				}
			} else {
				$AGENTS{$source}{'count'} += 1;
			}
			# Silence source.
			if ((defined ($SILENCEDSOURCES{$source})) && ($SILENCEDSOURCES{$source} > $curr_time)) {
				next;
			}
			if ($pa_config->{'snmp_storm_protection'} > 0 && $AGENTS{$source}{'count'} > $pa_config->{'snmp_storm_protection'}) {
				if ($AGENTS{$source}{'event'} == 0) {
					$SILENCEDSOURCES{$source} = $curr_time + $pa_config->{'snmp_storm_silence_period'};
					my $silenced_time = ($pa_config->{'snmp_storm_silence_period'} eq 0 ? $pa_config->{"snmp_storm_timeout"} : $pa_config->{'snmp_storm_silence_period'});
					pandora_event ($pa_config, "Too many traps coming from $source. Silenced for " . $silenced_time . " seconds.", 0, 0, 4, 0, 0, 'system', 0, $dbh);
				}
				$AGENTS{$source}{'event'} = 1;
				next;
			}

			# Either buffer or process the trap.
			if (source_lock($pa_config, $source, $local_sources) == 0) {
				push(@buffer, $line);
			} else {
				push (@tasks, $line);
			}
		}
	}

	# Save the buffer for the next run.
	$BUFFER->{'fd'} = \@buffer;

	return @tasks;
}

###############################################################################
# Data consumer.
###############################################################################
sub data_consumer ($$) {
	my ($self, $task) = @_;
	my ($pa_config, $server_id, $dbh) = ($self->getConfig(), $self->getServerID(), $self->getDBH());

	pandora_snmptrapd ($pa_config, $task, $server_id, $dbh);
	
	# Unlock.
	if ($pa_config->{'snmpconsole_lock'} == 1) {
		my ($ver, $date, $time, $source, $null) = split(/\[\*\*\]/, $task, 5);
		if ($ver eq "SNMPv2" || $pa_config->{'snmp_pdu_address'} eq '1' ) {
			$source =~ s/(?:(?:TCP|UDP):\s*)?\[?([^] ]+)\]?(?::-?\d+)?(?:\s*->.*)?$/$1/;
		}
		source_unlock($pa_config, $source);
	}
}

##########################################################################
# Process SNMP log file.
##########################################################################
sub pandora_snmptrapd {
	my ($pa_config, $line, $server_id, $dbh) = @_;

	(my $trap_ver, $line) = split(/\[\*\*\]/, $line, 2);

	# Process SNMP filter
	return if (matches_filter ($dbh, $pa_config, $line) == 1);

	logger($pa_config, "Reading trap '$line'", 10);
	my ($date, $time, $source, $oid, $type, $type_desc, $value, $data) = ('', '', '', '', '', '', '', '');

	if ($trap_ver eq "SNMPv1") {
		($date, $time, $source, $oid, $type, $type_desc, $value, $data) = split(/\[\*\*\]/, $line, 8);

		$value = limpia_cadena ($value);

		# Try to save as much information as possible if the trap could not be parsed
		$oid = $type_desc if ($oid eq '' || $oid eq '.');

		if (!defined($oid)) {
			logger($pa_config, "[W] snmpTrapOID not found (Illegal SNMPv1 trap?)", 5);
			return;
		}

	} elsif ($trap_ver eq "SNMPv2") {
		($date, $time, $source, $data) = split(/\[\*\*\]/, $line, 4);
		my @data = split(/\t/, $data);

		shift @data; # Drop unused 1st data.
		$oid = shift @data;

		if (!defined($oid)) {
			logger($pa_config, "[W] snmpTrapOID not found (Illegal SNMPv2 trap?)", 5);
			return;
		}
		$oid =~ s/.* = OID: //;
		if ($oid =~ m/^\.1\.3\.6\.1\.6\.3\.1\.1\.5\.([1-5])$/) {
			$type = $1 - 1;
		} else {
			$type = 6;
		}
		$data = join("\t", @data);
	}

	if ($trap_ver eq "SNMPv2" || $pa_config->{'snmp_pdu_address'} eq '1' ) {
		# extract IP address from %b part:
		#  * destination part (->[dest_ip]:dest_port) appears in Net-SNMP > 5.3
		#  * protocol name (TCP: or UDP:) and bracketted IP addr w/ port number appear in
		#    Net-SNMP > 5.1 (Net-SNMP 5.1 has IP addr only).
		#  * port number is signed (often negative) in Net-SNMP 5.2
		$source =~ s/(?:(?:TCP|UDP):\s*)?\[?([^] ]+)\]?(?::-?\d+)?(?:\s*->.*)?$/$1/;
	}

	my $timestamp = $date . ' ' . $time;
	my ($custom_oid, $custom_type, $custom_value) = ('', '', '');

	# custom_type, custom_value is not used since 4.0 version, all custom data goes on custom_oid
	$custom_oid = $data;

	#Trap forwarding
	if ($pa_config->{'snmp_forward_trap'}==1) {
		my $trap_data_string = "";

		#We loop through all the custom data of the received trap, creating the $trap_data_string string to forward the trap properly
		while ($data =~ /([\.\d]+)\s=\s([^:]+):\s([\S ]+)/g) {
			my ($trap_data, $trap_type, $trap_value) = ($1, $2, $3);
			if ($trap_type eq "INTEGER") {
				#FIX for translated traps from IF-MIB.txt MIB
				$trap_value =~ s/\D//g;
				$trap_data_string = $trap_data_string . "$trap_data i $trap_value ";
			}
			elsif ($trap_type eq "UNSIGNED"){
				$trap_data_string = $trap_data_string . "$trap_data u $trap_value ";
			}
			elsif ($trap_type eq "COUNTER32"){
			        $trap_data_string = $trap_data_string . "$trap_data c $trap_value ";
			}
			elsif ($trap_type eq "STRING"){
			        $trap_data_string = $trap_data_string . "$trap_data s $trap_value ";
			}
			elsif ($trap_type eq "HEX STRING"){
			        $trap_data_string = $trap_data_string . "$trap_data x $trap_value ";
			}
			elsif ($trap_type eq "DECIMAL STRING"){
			        $trap_data_string = $trap_data_string . "$trap_data d $trap_value ";
			}
			elsif ($trap_type eq "NULLOBJ"){
			        $trap_data_string = $trap_data_string . "$trap_data n $trap_value ";
			}
			elsif ($trap_type eq "OBJID"){
			        $trap_data_string = $trap_data_string . "$trap_data o $trap_value ";
			}
			elsif ($trap_type eq "TIMETICKS"){
			        $trap_data_string = $trap_data_string . "$trap_data t $trap_value ";
			}
			elsif ($trap_type eq "IPADDRESS"){
			        $trap_data_string = $trap_data_string . "$trap_data a $trap_value ";
			}
			elsif ($trap_type eq "BITS"){
			        $trap_data_string = $trap_data_string . "$trap_data b $trap_value ";
			}
		}

		#We distinguish between the three different kinds of SNMP forwarding
		if ($pa_config->{'snmp_forward_version'} eq '3') {
			system("snmptrap -v $pa_config->{'snmp_forward_version'} -n \"\" -a $pa_config->{'snmp_forward_authProtocol'} -A $pa_config->{'snmp_forward_authPassword'} -x $pa_config->{'snmp_forward_privProtocol'} -X $pa_config->{'snmp_forward_privPassword'} -l $pa_config->{'snmp_forward_secLevel'} -u $pa_config->{'snmp_forward_secName'} -e $pa_config->{'snmp_forward_engineid'} $pa_config->{'snmp_forward_ip'} '' $oid $trap_data_string");
		}
		elsif ($pa_config->{'snmp_forward_version'} eq '2' || $pa_config->{'snmp_forward_version'} eq '2c') {
			system("snmptrap -v 2c -n \"\" -c $pa_config->{'snmp_forward_community'} $pa_config->{'snmp_forward_ip'} '' $oid $trap_data_string");
		}
		elsif ($pa_config->{'snmp_forward_version'} eq '1') {
			#Because of tne SNMP v1 protocol, we must perform additional steps for creating the trap
			my $value_sending = "";
			my $type_sending = "";

			if ($value eq ''){
				$value_sending = "\"\"";
			}
			else {
				$value_sending = $value;
				$value_sending =~ s/[\$#@~!&*()\[\];.,:?^ `\\\/]+//g;
			}
			if ($type eq ''){
				$type_sending = "\"\"";
			}
			else{
				$type_sending = $type;
			}

			system("snmptrap -v 1 -c $pa_config->{'snmp_forward_community'} $pa_config->{'snmp_forward_ip'} $oid \"\" $type_sending $value_sending \"\" $trap_data_string");
		}
	}

	# Insert the trap into the DB
	if (! defined(enterprise_hook ('snmp_insert_trap', [$pa_config, $source, $oid, $type, $value, $custom_oid, $custom_value, $custom_type, $timestamp, $server_id, $dbh]))) {
		my $trap_id = db_insert ($dbh, 'id_trap', 'INSERT INTO ttrap (timestamp, source, oid, type, value, oid_custom, value_custom,  type_custom, utimestamp) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
								 $timestamp, $source, $oid, $type, $value, $custom_oid, $custom_value, $custom_type, time());
		logger ($pa_config, "Received SNMP Trap from $source", 4);

		# Evaluate alerts for this trap
		pandora_evaluate_snmp_alerts ($pa_config, $trap_id, $source, $oid, $type, $oid, $value, $custom_oid, $dbh);
	}

	# Delay the consumption of the next task.
	sleep($pa_config->{'snmp_delay'}) if ($pa_config->{'snmp_delay'} > 0);
}

########################################################################################
# Returns 1 if the given string matches any SNMP filter, 0 otherwise.
########################################################################################
sub matches_filter ($$$) {
	my ($dbh, $pa_config, $string) = @_;
	
	my @filter_unique_functions = get_db_rows ($dbh, 'SELECT DISTINCT(unified_filters_id) FROM tsnmp_filter ORDER BY unified_filters_id');
	
	foreach my $filter_unique_func (@filter_unique_functions) {
		# Get filters
		my @filters = get_db_rows ($dbh, 'SELECT filter FROM tsnmp_filter WHERE unified_filters_id = ' . $filter_unique_func->{'unified_filters_id'});
		
		my $eval_acum = 1;
		foreach my $filter (@filters) {
			my $regexp = safe_output($filter->{'filter'}) ;
			my $eval_result;

			# eval protects against server down (by invalid regular expressions)
			$eval_result = eval {
				$string =~ m/$regexp/i ;
			};

			if ($eval_result && $eval_acum) {
				$eval_acum = 1;
			}
			else {
				$eval_acum = 0;
				last;
			}
		}
		
		if ($eval_acum) {
			return 1;
		}
	}
	
	return 0;
}

########################################################################################
# Start snmptrapd, attempting to kill it if it is already running. Returns 0 if
# successful, 1 otherwise.
########################################################################################
sub start_snmptrapd ($) {
	my ($config) = @_;
	
	my $pid_file = '/var/run/pandora_snmptrapd.pid';
	my $snmptrapd_running = 0;

	# Manual start of snmptrapd
	if ($config->{'snmp_trapd'} eq 'manual') {
		my $noSNMPTrap = "No SNMP trap daemon configured. Start snmptrapd manually.";
		logger ($config, $noSNMPTrap, 1);
		print_message ($config, " [*] $noSNMPTrap", 1);

		if (! -f $config->{'snmp_logfile'}) {
			my $noLogFile = "SNMP log file " . $config->{'snmp_logfile'} . " not found.";
			logger ($config, $noLogFile, 1);
			print_message ($config, " [E] $noLogFile", 1);
			return 1;
		}

		return 0;
	}

	if ( -e $pid_file && open (PIDFILE, $pid_file)) {
		my $pid = <PIDFILE> + 0;
		close PIDFILE;

		# Check if snmptrapd is running
		if ($snmptrapd_running = kill (0, $pid)) {
			my $alreadyRunning = "snmptrapd (pid $pid) is already running, attempting to kill it...";
			logger ($config, $alreadyRunning, 1);
			print_message ($config, " [*] $alreadyRunning ", 1);
			kill (9, $pid);
		}
	}

	# Ignore auth failure traps
	my $snmp_ignore_authfailure = ($config->{'snmp_ignore_authfailure'} eq '1' ? ' -a' : '');

	# Select agent-addr field of the PDU or PDU source address for V1 traps and PDU source hostname for V2 traps
	my $address_format1 = ($config->{'snmp_pdu_address'} eq '0' ? '%a' : '%b');
	my $address_format2 = ($config->{'snmp_pdu_address'} eq '0' ? '%B' : '%b');

	my $snmptrapd_args = ' -t ' . $config->{'snmptrapd_args'} . $snmp_ignore_authfailure . ' -Lf ' . $config->{'snmp_logfile'} . ' -p ' . $pid_file;
	$snmptrapd_args .=  ' --format1=SNMPv1[**]%4y-%02.2m-%l[**]%02.2h:%02.2j:%02.2k[**]' . $address_format1 . '[**]%N[**]%w[**]%W[**]%q[**]%v\\\n';
	$snmptrapd_args .=  ' --format2=SNMPv2[**]%4y-%02.2m-%l[**]%02.2h:%02.2j:%02.2k[**]' . $address_format2 . '[**]%v\\\n';

	if (system ($config->{'snmp_trapd'} . $snmptrapd_args . " >$DEVNULL 2>&1") != 0) {
		my $showError = "Could not start snmptrapd.";
		logger ($config, $showError, 1);
		print_message ($config, " [E] $showError ", 1);
		return 1;
	}

	print_message ($config, " [*] snmptrapd started and running.", 1);

	return 0;
}

###############################################################################
# Read SNMP Log file with buffering (to handle multi-line Traps).
# Return reference of array (file-pos, line-data) if successful, undef othersise.
###############################################################################
sub read_snmplogfile($) {
	my ($fs) = @_;
	my $line;
	my $pos;

	# Reading from a temporary buffer.
	if (ref($fs->{'fd'}) eq 'ARRAY') {
		if ($#{$fs->{'fd'}} < 0) {
			return undef;
		}

		return [0, shift(@{$fs->{'fd'}})];
	}

	if(defined($fs->{'read_ahead_line'})) {
		# Restore saved line
		$line = $fs->{'read_ahead_line'};
		$pos = $fs->{'read_ahead_pos'};
	}
	else {
		# No saved line
		my $fd = $fs->{'fd'};
		$line = <$fd>;
		$pos = tell($fs->{'fd'});
	}

	return undef if (! defined($line));

	my $retry_count = 0;

	# More lines ?
	while(1) {
		my $fd = $fs->{'fd'};
		while($fs->{'read_ahead_line'} = <$fd>) {

			# Get current file position
			$fs->{'read_ahead_pos'} = tell($fs->{'fd'});

			# Get out of the loop if you find another Trap
			last if($fs->{'read_ahead_line'} =~ /^SNMP/ );

			# $fs->{'read_ahead_line'} looks continued line...

			# Append to the line and correct the position
			chomp($line);
			$line .= "$fs->{'read_ahead_line'}";
			$pos = $fs->{'read_ahead_pos'};
		}

		# if $line looks incomplete, try to get continued line
		# just within 10sec.  After that, giving up to complete it
		# and flush $line as it is.
		last if(chomp($line) > 0  || $retry_count++ >= 10);

		sleep(1);
	}

	# return fetched line with file position to be saved.
	return [$pos, $line];
}

###############################################################################
# Initialize the fs structure for a trap log file.
###############################################################################
sub init_log_file($$$) {
	my ($config, $fs) = @_;

	# Process index file, if available
	($fs->{'idx_file'}, $fs->{'last_line'}, $fs->{'last_size'}) = ($fs->{'log_file'} . '.index', 0, 0);
	if (-e  $fs->{'idx_file'}) {
		open (my $idxfd, $fs->{'idx_file'}) or return;
		my $idx_data = <$idxfd>;
		close $idxfd;
		($fs->{'last_line'}, $fs->{'last_size'}) = split(/\s+/, $idx_data);
	}
	my $log_size = (stat ($fs->{'log_file'}))[7];

	# New SNMP log file found
	if ($log_size < $fs->{'last_size'}) {
		unlink ($fs->{'idx_file'});
		($fs->{'last_line'}, $fs->{'last_size'}) = (0, 0);
	}

	# Skip already processed lines
	read_snmplogfile($fs) for (1..$fs->{'last_line'});
}

###############################################################################
# Reset the index if the file has been truncated.
###############################################################################
sub reset_if_truncated($$) {
	my ($pa_config, $fs) = @_;

	if (!defined($fs->{'log_file'})) {
		return;
	}

	my $log_size = (stat ($fs->{'log_file'}))[7];

	# New SNMP log file found
	if ($log_size < $fs->{'last_size'}) {
		logger ($pa_config, 'File ' . $fs->{'log_file'} . ' was truncated.', 10);
		unlink ($fs->{'idx_file'});
		($fs->{'last_line'}, $fs->{'last_size'}) = (0, 0);
		seek($fs->{'fd'}, 0, 0);
	}
}

##########################################################################
# Get a lock on the given source. Return 1 on success, 0 otherwise.
##########################################################################
sub source_lock($$$) {
	my ($pa_config, $source, $local_sources) = @_;

	# Locking is disabled.
	if ($pa_config->{'snmpconsole_lock'} == 0) {
		return 1;
	}

	if (defined($local_sources->{$source})) {
		return 0;
	}

	$local_sources->{$source} = 1;
	$SourceSem->down ();
	$Sources{$source} = 1;
	$SourceSem->up ();

	return 1;
}

##########################################################################
# Remove the lock on the given source.
##########################################################################
sub source_unlock {
	my ($pa_config, $source) = @_;

	# Locking is disabled.
	if ($pa_config->{'snmpconsole_lock'} == 0) {
		return;
	}

	$SourceSem->down ();
	delete ($Sources{$source});
	$SourceSem->up ();
}

###############################################################################
# Clean-up when the server is destroyed.
###############################################################################
sub DESTROY {
	my $self = shift;

	if ($self->{'snmp_trapd'} ne 'manual') {
		my $pid_file = '/var/run/pandora_snmptrapd.pid';
		if (-e $pid_file) {
			my $pid = `cat $pid_file 2>$DEVNULL`;
			if (defined($pid) && ("$pid" ne "") && looks_like_number($pid)) {
					system ("kill -9 $pid");
			}

			unlink ($pid_file);
		}
	}
}

1;
__END__
