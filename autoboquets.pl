#!/usr/bin/perl
# Perl version of AutoBouquets E2 28.2E by LraiZer for www.ukcvs.org
# modified to integrate with TVHeadend
# by Jonathan Kempson - jkempson@gmail.com
use 5.010;
use strict;
use warnings;
use Data::Dumper;
use LWP::Simple qw(get);
use JSON;
use URI::Escape;
use List::Util qw(first);
use LWP::Simple qw($ua head);
# Required regional data/region here (use SD version if HD channel verification required)
my $data_sd   = "4097";
my $region_sd = "07";
# HD data/region here to be verified. Set to "" to skip HD channel verification
my $data_hd   = "";
my $region_hd = "";
# TVH configuration
my $tag_channels  = 1;
my $tvh_user      = "someuser";
my $tvh_pass      = "somepassword";
my $tvh_ip        = "someip";
my $tvh_proto     = "http";
my $tvh_port      = "9981";
my $tvh_tag       = "TV channels";
my $icons_enabled = 1;
# Change 'on' => 1 to 'on' => 0 if you don't want that channel group
my %chan_tags = (
    'Entertainment'         => { 'num' => 101,  'on' => 1 },
    'Lifestyle and Culture' => { 'num' => 240,  'on' => 1 },
    'Movies'                => { 'num' => 301,  'on' => 1 },
    'Music'                 => { 'num' => 350,  'on' => 1 },
    'Sports'                => { 'num' => 401,  'on' => 1 },
    'News'                  => { 'num' => 501,  'on' => 1 },
    'Documentaries'         => { 'num' => 520,  'on' => 1 },
    'Religious'             => { 'num' => 580,  'on' => 1 },
    'Kids'                  => { 'num' => 601,  'on' => 1 },
    'Shopping'              => { 'num' => 640,  'on' => 1 },
    'Sky Box Office'        => { 'num' => 700,  'on' => 1 },
    'International'         => { 'num' => 780,  'on' => 1 },
    'Gaming and Dating'     => { 'num' => 861,  'on' => 1 },
    'Specialist'            => { 'num' => 881,  'on' => 1 },
    'Adult'                 => { 'num' => 900,  'on' => 1 },
    'Other'                 => { 'num' => 950,  'on' => 1 },
    'Radio'                 => { 'num' => 3101, 'on' => 0 },
);
# Manual add channel, number:SID, for channels that may not be in your bouquet		
my @sid_adds  = ("131:10155");
say "Started";
my $tvh_url = $tvh_proto . "\:\/\/" . $tvh_user . "\:" . $tvh_pass . "\@" . $tvh_ip . "\:" . $tvh_port;
say "Get Channel Tags...";
my %chan_ids = tvhTagHash( $tvh_tag, \%chan_tags );
say "Done";
#my $f_dvb = "/tmp/abm_dvb.txt";
#my @dvb   = readFile($f_dvb);
# Run dvbsnoop
my @dvb = `dvbsnoop -nph -n 500 0x11`;
if ( scalar(@dvb) <= 1 ) { die "No data received. You must have root access?"; }
# Get SDT
say "Get SDT...";
my @sdt = serviceDescriptionTable( \@dvb );
say "Done";
# Get service lists
say "Get services";
my @services_sd    = populateServices($data_sd, $region_sd, @dvb, @sdt);
@services_sd = sort( uniqArray(@services_sd) );
say "Done";
my @merged_services;
if (($data_hd ne "") && ($region_hd ne "")) {
	my @services_hd    = populateServices($data_hd, $region_hd, @dvb, @sdt);
	@services_hd = sort( uniqArray(@services_hd) );
	my @services_hd_checked;
	$ua->timeout(10);
	my @tvh_services = tvhQuery("mpegts/service/grid?dir=ASC&limit=100000&sort=sid&start=0");
	foreach my $s_hd (@services_hd) {
		my $dupe = 0;
		foreach my $s_sd (@services_sd) {
			if ($s_hd eq $s_sd) { $dupe = 1; }
		}
		if ($dupe == 0) { 
			my @conv = split( " ", $s_hd );
			my $serv_type = tvhServiceType( hex( $conv[2] ), \@tvh_services );
		
			# dvb_servicetype seems to be HD channels? Use to ignore SD channels returned in HD bouquet.
			if ($serv_type == 25) {	    
				my $chan_num  = hex( $conv[0] );
				my $chan_uuid = tvhServiceID( hex( $conv[2] ), \@tvh_services );
				my $chan_name = lookupService( "$conv[2]", \@sdt );
				my $url = "$tvh_url/stream/service/$chan_uuid";
				print "Testing channel $chan_num $chan_name...";
				if (head($url)) { 
					push (@services_hd_checked, $s_hd);
					print "ok\n"; 
				} else { 
					print "fail\n";
				}
			}
		}
	}
	foreach my $s_sd (@services_sd) {
		my @conv = split( " ", $s_sd );
		my $chan_num  = hex( $conv[0] );
		my $replace = $s_sd;
		foreach my $s_hd (@services_hd_checked) {
				my @conv_hd = split( " ", $s_hd );
				my $chan_num_hd  = hex( $conv_hd[0] );
				if ($chan_num eq $chan_num_hd) { $replace = $s_hd; }
		}
		push (@merged_services, $replace);
	}
} else {
	@merged_services = @services_sd;
}
foreach my $add (@sid_adds) {
	my @arr = split(":",$add);
	$arr[0] = sprintf( "%04x", $arr[0] );
	$arr[1] = sprintf( "%04x", $arr[1] );
	push @merged_services, "$arr[0] 0000 $arr[1] 0000";
}
@merged_services = sort( uniqArray(@merged_services) );
# Populate channels in TVH
say "Populate channels in TVH...";
updateTVH( \@merged_services, $tvh_tag, $tag_channels );
say "Done";
exit;
################################################################################
sub populateServices {
    my ( $data, $region, $dvb, $sdt ) = @_;
	my (@svcs, @sections);
	
	$region    = sprintf( "%02x", $region );
		
	say "Process regional services first...";
	processServices( $data, $region, \@dvb, \@svcs, \@sdt );
	say "Done";
	say "Everything else...";
	if ( ( $region ne "33" ) && ( $region ne "32" ) ) {
		# Use different base services if region is Irish
		processServices( "4104", "21", \@dvb, \@svcs, \@sdt );
	}
	else {
		processServices( "4101", "01", \@dvb, \@svcs, \@sdt );
	}
	
	say "Done";
	return @svcs;
}
sub updateTVH {
    my ( $services, $tvh_tag, $tag_channels ) = @_;
    my @tvh_tags = tvhQuery("channeltag/list?enum=true");
    my $tag_id = tvhTagID($tvh_tag);
    # Get all services from tvh
    my @tvh_services = tvhQuery("mpegts/service/grid?dir=ASC&limit=100000&sort=sid&start=0");
    my @tvh_channels = tvhQuery("channel/grid?dir=ASC&limit=100000&sort=number&start=0");
    my @chan_list;
    my @sid_dupes;
		
    foreach my $line (@$services) {
		my @conv = split( " ", $line );
        my $chan_num  = hex( $conv[0] );
        my $chan_name = lookupService( "$conv[2]", \@sdt );
        my $chan_epg  = hex( $conv[1] );
        my $chan_logo = "http://tv.sky.com/logo/0/0/skychb" . $chan_epg . ".png";
						
        my ( @j_sid, @j_tag );
        my $chan_uuid = tvhServiceID( hex( $conv[2] ), \@tvh_services );
        push @j_sid, $chan_uuid;
        # Duplicate channels with different channel numbers seem to cause problems with EPG in XBMC (perhaps others)?
        # EPG sometimes isn't imported for channels which are assigned multiple channel numbers.
        # Skip channel if it has been seen earlier.
        my $skip = 0;
        if ( first { $_ eq $chan_uuid } @sid_dupes ) {
            $skip = 1;
        }
        push @sid_dupes, $chan_uuid;
        # Ignore useless channels 65535
        if ( $chan_num == 65535 ) { $skip = 1; }
        push @j_tag, $tag_id;
        # Add tag info if enabled
        if ( $tag_channels == 1 ) {
            if ( $chan_tags{ chanToTag($chan_num) }->{on} == 1 ) {
                push @j_tag, $chan_ids{ chanToTag($chan_num) };
            }
            else {
                $skip = 1;
            }
        }
        # Create hash of channel data to be added
        if ( $skip == 0 ) {
            my %chan_hash = (
                'name'         => $chan_name,
                'number'       => $chan_num,
                'services'     => \@j_sid,
                'tags'         => \@j_tag,
                'dvr_pre_time' => '0',
                'dvr_pst_time' => '0'
            );
            
            if ($icons_enabled !=0) {
            	$chan_hash{'icon'} = $chan_logo;
            }
            push @chan_list, $chan_num;
            tvhUpdateChannel( \@tvh_channels, $tag_id, \%chan_hash );
        }
    }
    # Remove orphan channels
    foreach my $chan (@tvh_channels) {
        my $tag_check = 0;
        foreach my $tag ( @{ $chan->{tags} } ) {
            if ( $tag eq $tag_id ) { $tag_check = 1; }
        }
        my $found = 0;
        for my $line (@chan_list) {
            if ( $chan->{number} eq $line ) { $found = 1; }
        }
        if ( ( $found == 0 ) && ( $tag_check == 1 ) ) {
            say "Removing orphaned channel $chan->{number} $chan->{name}";
            get( $tvh_url . "/api/idnode/delete?uuid=" . uri_escape( $chan->{uuid} ) );
        }
    }
}
sub tvhTagHash {
    my ( $tvh_tag, $chan_tags ) = @_;
    my @tvh_tags;
    push @tvh_tags, $tvh_tag;
    foreach my $ch ( sort keys %chan_tags ) {
        push @tvh_tags, $ch;
    }
    my %chan_ids;
    foreach my $ch (@tvh_tags) {
        my $tag_id = tvhTagID($ch);
        if ( !$tag_id ) {
            $tag_id = tvhCreateTag($ch);
        }
        $chan_ids{$ch} = $tag_id;
    }
    return %chan_ids;
}
sub chanToTag {
    my ( $chan, $chan_tags ) = @_;
    my $tag = "";
    foreach my $n ( sort { $chan_tags{$b}->{num} <=> $chan_tags{$a}->{num} } keys %chan_tags ) {
        if ( $chan >= $chan_tags{$n}->{num} ) {
            $tag = $n;
            last;
        }
    }
    return $tag;
}
sub tvhTagID {
    my ($tvh_tag) = @_;
    my @tvh_tags = tvhQuery("channeltag/list?enum=true");
    my $tag_id;
    foreach my $tag (@tvh_tags) {
        if ( $tag->{val} eq $tvh_tag ) { $tag_id = $tag->{key}; }
    }
    return $tag_id;
}
sub tvhCreateTag {
    my ($tag_name) = @_;
    my $post       = "{\"enabled\":true,\"name\":\"" . $tag_name . "\",\"internal\":false,\"icon\":\"\",\"titled_icon\":false,\"comment\":\"\"}";
	say "Adding channel tag $tag_name";
    get( $tvh_url."/api/channeltag/create?conf=".uri_escape($post)); 
    return tvhTagID($tag_name);
}
sub tvhUpdateChannel {
    my ( $tvh_channels, $tag_id, $post_json ) = @_;
    my $matches    = 0;
    my $chan_exist = "";
    for my $line (@$tvh_channels) {
        my $tag_check = 0;
        foreach my $tag ( @{ $line->{tags} } ) {
            if ( $tag eq $tag_id ) { $tag_check = 1; }
        }
        if ( $tag_check == 1 ) {
            if ( $line->{number} eq $post_json->{number} ) {
                $matches    = 1;
                $chan_exist = $line->{uuid};
                my $servs      = join( "", sort( @{ $line->{services} } ) );
                my $post_servs = join( "", sort( @{ $post_json->{services} } ) );
                my $tags      = join( "", sort( @{ $line->{tags} } ) );
                my $post_tags = join( "", sort( @{ $post_json->{tags} } ) );
                
                if ( $line->{name} ne $post_json->{name} ) { $matches = 0 }
                                
                if ($icons_enabled == 1) {
                	if ( $line->{icon} ne $post_json->{icon} ) { $matches = 0 }
                }
                
                if ( $servs        ne $post_servs )        { $matches = 0 }
                if ( $tags         ne $post_tags )         { $matches = 0 }
                last;
            }
        }
    }
    if ( $matches == 0 ) {
        if ( $chan_exist ne "" ) {
            say "Deleting old channel $post_json->{number}";
            get( $tvh_url . "/api/idnode/delete?uuid=" . uri_escape($chan_exist) );
        }
        say "Adding channel $post_json->{number} $post_json->{name}";
        get( $tvh_url . "/api/channel/create?conf=" . uri_escape( encode_json($post_json) ) );
    }
}
sub tvhQuery {
    my ($query) = @_;
    my $url    = $tvh_url . '/api/' . $query;
    my $return = from_json( get($url) );
    return @{ $return->{entries} };
}
sub tvhServiceID {
    my ( $search, $decoded ) = @_;
    my $uuid = "";
    foreach my $line (@$decoded) {
        if ( $line->{sid} eq $search ) { $uuid = $line->{uuid}; last; }
    }
    return $uuid;
}
sub tvhServiceType {
    my ( $search, $decoded ) = @_;
    my $uuid = "";
    foreach my $line (@$decoded) {
        if ( $line->{sid} eq $search ) { $uuid = $line->{dvb_servicetype}; last; }
    }
    return $uuid;
}
sub uniqArray {
    return keys %{ { map { $_ => 1 } @_ } };
}
sub processServices {
    my ( $data, $region, $dvb, $svcs, $sdt ) = @_;
    my @sections = findSections( $data, \@dvb );
    return streamData( $region, \@sections, $svcs, \@sdt );
}
sub streamData {
    my ( $region, $sections, $conv_data, $sdt ) = @_;
    my ( @data, $hex, $ts, $code, $pcode );
    # If there is already data in services array then turn on duplicate checking
    my $check_dupes;
    if ( scalar(@$conv_data) > 0 ) {
        $check_dupes = 1;
    }
    else {
        $check_dupes = 0;
    }
    foreach my $line (@$sections) {
        if ( $line =~ /^    Transport_stream_ID/ ) {
            ($ts) = $line =~ /\(.*x([^\)]+)/;
            $ts    = trim($ts);
            $pcode = -1;
            push( @data, $hex );
            $hex = $ts;
        }
        if ( $line =~ /^                 00/ ) {
            $line =~ s /(.{74}).*/${1}/s;
            $line =~ s/\h+/ /g;
            $line = trim($line);
            $code = hex( substr( $line, 0, 4 ) );
            $line = substr( $line, 5 );
            if ( $code <= $pcode ) {
                push( @data, $hex );
                $hex = $ts;
            }
            $pcode = $code;
            $hex = $hex . $line;
        }
    }
    push( @data, $hex );
    shift @data;
    filterServices( \@data, $region );
    for my $line (@data) {
        my $count      = 1;
        my $number     = 7;
        my $serv_count = length($line) / 27;
        my $code       = substr( $line, 0, 4 );
        while ( $count < $serv_count ) {
            my @s = split( " ", substr( $line, $number, 27 ) );
            my $out = $s[6] . $s[7] . " " . $s[4] . $s[5] . " " . $s[1] . $s[2] . " " . $code;
            my $found = 0;
            if ( $check_dupes eq 1 ) {
                my $d = substr( $out, 0, 4 );
                if ( grep( /^$d/i, @$conv_data ) ) { $found = 1; }
            }
            if ( $found == 0 ) {
                push( @$conv_data, $out );
            }
            
            $number = $number + 27;
            $count++;
        }
    }
    return @$conv_data;
}
sub filterServices {
    my ( $data, $region ) = @_;
    my $i = 0;
    do {
        if ( ( substr( @$data[$i], 8, 2 ) ne $region ) && ( substr( @$data[$i], 5, 2 ) ne "ff" ) ) {
            splice @$data, $i, 1;
        }
        else {
            $i++;
        }
    } until ( $i == scalar(@$data) );
    return @$data;
}
sub lookupService {
    my $search = shift;
    my $sdt    = shift;
    foreach my $line (@$sdt) {
        if ( $line =~ /^$search/ ) {
            $search = substr( $line, 10 );
            last;
        }
    }
    return $search;
}
sub findSections {
    # Extract relevant sections from dvbsnoop array based on $data bouquet info
    my ( $data, $dvb ) = @_;
    my @sections_ref = sectionsRef( $data, \@dvb );
    my @sections;
    my $sec_first = ( @$dvb[ $sections_ref[0] + 18 ] =~ /Section_number: (.*) \(/ )[0];
    my $sec_last  = ( @$dvb[ $sections_ref[0] + 19 ] =~ /Section_number: (.*) \(/ )[0];
    my $sec_cycle;
    # Set loop stop point to prevent repeat data
    if ( $sec_first == 0 ) {
        $sec_cycle = $sec_last;
    }
    else {
        $sec_cycle = $sec_first - 1;
    }
    foreach my $line (@sections_ref) {
        my $strt = $line;
        do {
            $strt++;
            push( @sections, @$dvb[$strt] );
        } while !( @$dvb[$strt] =~ /CRC/ );
        # sec_num = current sequence position
        my $sec_num = ( @$dvb[ $line + 18 ] =~ /Section_number: (.*) \(/ )[0];
        # If position in sequence matches stop point then exit
        if ( $sec_num == $sec_cycle ) { last; }
    }
    return @sections;
}
sub sectionsRef {
    # Extract positions of Bouquet_ID for $data in dvbsnoop array
    my ( $data, $dvb ) = @_;
    my $cnt = 0;
    my @sections;
    foreach my $line (@$dvb) {
        if ( $line =~ /Bouquet_ID: $data/ ) {
            push( @sections, ( $cnt - 14 ) . "\n" );
        }
        $cnt++;
    }
    return @sections;
}
sub serviceDescriptionTable {
    # Finds all service data from the dvbsnoop array
    my $dvb = shift;
    # Match any line in this array
    my $match = join( "|",
        qr/^Transport_Stream_ID:/,
        qr/^    Service_id:/,
        qr/^    Free_CA_mode:/,
        qr/^            service_provider_name:/,
        qr/^            Service_name:/,
        qr/^                 0000:  /,
    );
    # Do not include matching line if a second check matches any values here (not sure why?)
    my $no_match = join( "|", qr/^                 0000:  00/, qr/^                 0000:  ff/, qr/^                 0000:  1d/, );
    my @services;
    foreach my $line (@$dvb) {
        if ( ( $line =~ $match ) && !( $line =~ $no_match ) ) {
            push( @services, $line );
        }
    }
    return processSDT( \@services );
}
sub processSDT {
    my $services = shift;
    my @return;
    my ( $tsid, $sid, $sn, $ca, $spn );
    foreach my $line (@$services) {
        if ( $line =~ /Transport_Stream_ID/ ) {
            $tsid = get_hex($line);
        }
        if ( $line =~ /Service_id:/ ) {
            $sid = get_hex($line);
            $sn  = "";
        }
        if ( $line =~ /Free_CA_mode:/ ) {
            $ca = get_hex($line);
            if   ( $ca == 0 ) { $ca = "FTA"; }
            else              { $ca = "NDS"; }
        }
        if ( $line =~ /service_provider_name:/ ) {
            $spn = get_txt($line);
        }
        if ( $line =~ /Service_name:/ ) {
            $sn = get_txt($line);
            #push @return, "$sid:$tsid#$ca:$spn:$sn";
            push @return, "$sid:$tsid:$sn";
        }
        if ( $line =~ /0000:/ ) {
            if ( length($sn) == 0 ) {
                # Need a regexp here, this isn't nice :S
                $sn = trim( substr( $line, 70 ) );
                # push @return, "$sid:$tsid#$ca:BSkyB:$sn";
                push @return, "$sid:$tsid:$sn";
            }
        }
    }
    @return = sort( uniqArray(@return) );
    return @return;
}
sub get_txt {
    if ( $_[0] =~ /"(.+?)"/ ) { return $1; }
}
sub get_hex {
    my $return;
    ($return) = $_[0] =~ /\(.*x([^\)]+)/;
    $return = trim($return);
    return $return;
}
sub trim {
    ( my $s = $_[0] ) =~ s/^\s+|\s+$//g;
    return $s;
}
sub readFile {
    open( FH, $_[0] );
    my @buf = <FH>;
    close(FH);
    return @buf;
}
