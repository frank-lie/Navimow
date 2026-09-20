#######################################################################################################
#
# 58_Navimow.pm 
#
# This modul ist used for control of Segway Navimow.
#
#######################################################################################################
# v0.2.6 - 20.09.2026 Bearer&UUID in MQTT-Connect, fix in GetDetail -> release for beta-testing
# v0.2.5 - 20.09.2026 fix for reading 'vehicleState' (HTTP=string <> MQTT=integer)
# v0.2.4 - 19.09.2026 set-cmd for mower device add noArg
# v0.2.3 - 19.09.2026 fix error when deleting iomaster, fix error on attrVal to start mqtt connect
# v0.2.2 - 18.09.2026 documentation
# v0.2.1 - 18.09.2026 extended logging & readingsUpdate
# v0.2.0 - 15.09.2026 seperate iomaster and devices
# v0.1.0 - 14.09.2026 mqtt support
# v0.0.4 - 02.09.2026 Code cleanup
# v0.0.3 - 31.08.2026 Commands start, stop, pause, resume, dock over Rest-API
# v0.0.2 - 30.07.2026 Get data from json
# v0.0.1 - 22.06.2026 Basic Oauth
#######################################################################################################

package main;

use strict;
use warnings;
use DevIo;

use Time::HiRes qw(gettimeofday time);
use HttpUtils;
use SetExtensions;

use vars qw(%FW_webArgs);

## try to use JSON::XS, otherwise use own decoding sub
my $json_xs_available = 1;
eval "use JSON::XS qw(decode_json); 1" or $json_xs_available = 0;

my $Navimow_version = 'v0.2.6 - 20.09.2026';

my $navimow_oauth_url = "https://navimow-h5-fra.willand.com/smartHome/login?channel=homeassistant";
my $navimow_token_url = "https://navimow-fra.ninebot.com/openapi/oauth/getAccessToken";

my $navimow_cloud_url =	"https://navimow-fra.ninebot.com";

###################################### Forward declarations ###########################################

sub Navimow_Initialize($);			# define the functions to be called 
sub Navimow_UUID;					# create uuid for requests
sub Navimow_CreateSecretState;		# create a seperate secret for OAuth2
sub Navimow_Define($$);				# handle define of master und indoor-devices 
sub Navimow_Undefine($$);			# handle undefine a device, remove timers und kill blockingcalls

sub Navimow_CallbackGetToken;		# extract the tokens from the response and store them in FHEM 
sub Navimow_GetToken($$);			# send the authorization-code to get the tokens
sub Navimow_RefreshToken($);		# do a refresh of the access-token, which is only valid for 1 hour

sub Navimow_Set($$@);				# handle the set commands of devices
sub Navimow_Get($$@);				# handle the get commands of devices
sub Navimow_Attr($$$;$);			# handle the change of attributes

sub Navimow_Polltimer($;$);			# schedule next polling interval
sub Navimow_Request($;$$$);			# get/post a request
sub Navimow_Response;				# receive data from the cloud

sub Navimow_GetDetail($$$);			# parse json
sub Navimow_Transformdata($$);		# transform json-txt to data

sub Navimow_MQTT_Connect($);		# send HTTP-request to initiate MQTT-session
sub Navimow_MQTT_Login($);		    # login in MQTT-session
sub Navimow_LengthPlusPayload($);	# calculate remaining length and append payload
sub Navimow_MQTT_Read($);		    # read the buffer und parse
sub Navimow_MQTT_Disconnect($$);	# disconnect and initiate a clean session
sub Navimow_MQTT_Keepalive($);		# ping every 60 seconds to get a response = alive

#######################################################################################################

sub Navimow_Initialize($)
{
	my ($hash) = @_;
	$hash->{DefFn}    = 'Navimow_Define';
	$hash->{UndefFn}  = 'Navimow_Undefine';
	$hash->{SetFn}    = 'Navimow_Set';
	$hash->{GetFn}    = 'Navimow_Get';
	$hash->{AttrFn}   = 'Navimow_Attr';
	$hash->{ReadFn}   = 'Navimow_MQTT_Read';
}

sub Navimow_UUID
{
	## create UUID for request 8-4-4-4-12 Hex-Format
	my @chars = ('0'..'9', 'a'..'f');
	my $len = 32;
	my $uuid = '';
	while($len--){ $uuid .= $chars[rand @chars] };
	substr($uuid, 20, 0, "-");
	substr($uuid, 16, 0, "-");
	substr($uuid, 12, 0, "-");
	substr($uuid, 8, 0, "-");
	return $uuid;
}

sub Navimow_CreateSecretState
{
	## create state parameter (secret) for OAuth2 
	my @chars = ('0'..'9', 'A'..'Z','a'..'z');
	my $len = 32;
	my $secret = '';
	while($len--){ $secret .= $chars[rand @chars] };
	return $secret;
}

sub Navimow_Define($$)
{
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def);
	
	if (int(@a) > 2 && $a[2] eq "?" ) {
		return "Syntax: define <NAME> Navimow <CLIENT_ID> <CLIENT_SECRET> <REDIRECT_URI>"; 
	};
	my $name = $a[0]; # a[0]=name; a[1]=Navimow; a[2]..a[4]= parameters
	
	## handle define of mow units
	if (int(@a) == 3) {
		my $iomaster = $modules{Navimow}{defptr}{IOMASTER};
		return 'Cannot modify master device to mow device!' if (defined($iomaster) && $hash eq $iomaster);
		$modules{Navimow}{defptr}{$a[2]} = $hash;
		setDevAttrList($name, '' . $readingFnAttributes);
		if ($init_done) {
			CommandAttr(undef, '-silent '.$name.' room Navimow_Devices') if(!defined(AttrVal($name,"room",undef)));
			CommandAttr(undef, '-silent '.$name.' event-on-change-reading .*') if(!defined(AttrVal($name,"event-on-change-reading",undef)));			
		}
	} else {
		## handle define of IO-MASTER device as a bridge
		my $iomaster = $modules{Navimow}{defptr}{IOMASTER};
		return "Master device already defined as $iomaster->{NAME} !" if (defined($iomaster) && $iomaster->{NAME} ne $name);
		$hash->{INTERVAL} = 900;
		$hash->{VERSION} = $Navimow_version;
		$hash->{helper}{secret_state} = Navimow_CreateSecretState();
	
		$hash->{CLIENT_ID}     = defined($a[2]) ? $a[2] : 'homeassistant';
		$hash->{CLIENT_SECRET} = defined($a[3]) ? $a[3] : '57056e15-722e-42be-bbaa-b0cbfb208a52';
		$hash->{REDIRECT_URI}  = defined($a[4]) ? $a[4] : 'http://localhost/callback';
	
		$hash->{DEF} = $hash->{CLIENT_ID}.' '.$hash->{CLIENT_SECRET}.' '.$hash->{REDIRECT_URI};
		
		$hash->{AUTHORIZATION_LINK} = "<html><b><a href=\"".$navimow_oauth_url.#"authorize?".
			"&response_type=code".
			"&client_id=".$hash->{CLIENT_ID}.
			"&redirect_uri=".urlEncode($hash->{REDIRECT_URI}).
			"&state=".$hash->{helper}{secret_state}.
			"\" target=\"_blank\">Segway Navimow Login (OAuth2)</a></b> ".
			"</html>";
		
		$modules{Navimow}{defptr}{IOMASTER} = $hash;
		
		my (undef, $r_token) = getKeyValue('Navimow_refresh_token');
	
		if (defined($r_token)) {
			$hash->{helper}{REFRESH_TOKEN} = $r_token;
			Log3($name, 2, "$name (Define): Refresh-Token ready to use.");
		} else {
			## else delete old tokens
			delete $hash->{helper}{ACCESS_TOKEN} if (defined($hash->{helper}) && defined($hash->{helper}{ACCESS_TOKEN}));
			delete $hash->{helper}{REFRESH_TOKEN} if (defined($hash->{helper}) && defined($hash->{helper}{REFRESH_TOKEN}));
		}
		 
		setDevAttrList($name, 'autocreate:1,0 interval saveRawData:1,0 MQTT:1,0 '. $readingFnAttributes);
		if ($init_done) {
			CommandAttr(undef, '-silent '.$name.' room Navimow_Devices') if(!defined(AttrVal($name,"room",undef)));
			CommandAttr(undef, '-silent '.$name.' event-on-change-reading .*') if(!defined(AttrVal($name,"event-on-change-reading",undef)));
			CommandAttr(undef, '-silent '.$name.' autocreate 1') if(!defined(AttrVal($name,"autocreate",undef)));			
			CommandAttr(undef, '-silent '.$name.' MQTT 1') if(!defined(AttrVal($name,"MQTT",undef)));
			CommandAttr(undef, '-silent '.$name.' interval 900') if(!defined(AttrVal($name,"interval",undef)));
		}
	}
	return undef;
}

sub Navimow_Undefine($$)
{
	my ($hash, $arg) = @_;
	my $iomaster = $modules{Navimow}{defptr}{IOMASTER};
	if ( defined($iomaster) && $hash eq $iomaster ) {
		setKeyValue('Navimow_refresh_token',undef);
		delete $modules{Navimow}{defptr}{IOMASTER};
		Navimow_MQTT_Disconnect($hash, 0);
		RemoveInternalTimer($hash);
	}
	delete $modules{Navimow}{defptr}{$hash->{DEF}} if (defined($hash->{DEF}));
	return undef;
}

sub Navimow_CallbackGetToken
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	my $name = $hash->{NAME};
		
	if ( $err || $param->{code} != 200 ) { 
		my $errortext = 'Navimow (CallbackGetToken) failed: ';
		if ($err) {
			$errortext .= $err ;
		} else {
			$errortext .= "HTTP-Status-Code=" . $param->{code} if (defined($param->{code}));
			$errortext .= " Response: " . $data if (defined($data));
		}
		Log3($name, 2, "$name (CallbackGetToken): $errortext");
		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, 'token_status', $errortext );
		readingsBulkUpdate($hash, 'token_type', 'invalid' );
		readingsEndUpdate($hash,1);
		return;
	}
	
	## extract the tokens quick and dirty
	my ($a_token) = ( $data =~ m/"access.?token"\s*:\s*"([^"]+)/i );
	my ($r_token) = ( $data =~ m/"refresh.?token"\s*:\s*"([^"]+)/i );
	my ($exp) = ( $data =~ m/"expires.?in"\s*:\s*"?([^",}]+)/i );
	my ($t_type) = ( $data =~ m/"token.?type"\s*:\s*"([^"]+)/i );
	
	if (!defined($a_token) || !defined($r_token)) {
		Log3($name, 2, "$name (CallbackGetToken): No TokenSet found");
		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, 'token_status', 'failed: no TokenSet retrieved');
		readingsBulkUpdate($hash, 'token_type', 'none');
		readingsEndUpdate($hash,1);
		return;
	}	
	
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, 'expires_in', $exp) if (defined($exp));
	readingsBulkUpdate($hash, 'token_type', $t_type) if (defined($t_type));
	readingsBulkUpdate($hash, 'token_status', 'TokenSet successfully stored');
	readingsEndUpdate($hash,1);
	
	$hash->{helper}{ACCESS_TOKEN} = $a_token;
	$hash->{helper}{REFRESH_TOKEN} = $r_token;	
	setKeyValue('Navimow_refresh_token',$r_token);
	
	Log3($name, 4, "$name (CallbackGetToken): TokenSet successfully stored");
	
	## schedule next request in 1 second
	Navimow_Polltimer($hash, 1);
	
	## do automatic refresh token 1 minute before expired
    InternalTimer(gettimeofday()+ReadingsNum($name,'expires_in',3600)-60,'Navimow_RefreshToken',$hash,0);
	
}

sub Navimow_GetToken($$)
{
	my ($hash, $code) = @_;
	my $name = $hash->{NAME};

	$code = urlDecode($code);
	$code = $1 if ($code =~ m/code=([^&]*)/);
	
	if (length($code)<8) {
		$code = $FW_webArgs{"code"} if defined($FW_webArgs{"code"});
		if (length($code)<8) {
			readingsSingleUpdate($hash, 'token_status', 'no valid AuthCode', 1 );
			return "No valid AuthCode";
		};
		
	}	
	
	Log3($name, 5, "$name (GetToken): request for TokenSet .. (AuthCode = $code )");
	
	HttpUtils_NonblockingGet(
	{
		callback => \&Navimow_CallbackGetToken,
		method => 'POST',
		hash => $hash,
		url => $navimow_token_url,
		timeout => 10,
		data => 
		{
			grant_type => 'authorization_code', 
			client_id => $hash->{CLIENT_ID},
			client_secret => $hash->{CLIENT_SECRET},
			code => $code,
			redirect_uri => $hash->{REDIRECT_URI},
			state => $hash->{helper}{secret_state}
		}
	});
	readingsSingleUpdate($hash, 'token_status', 'request for TokenSet ..', 1 );
	return undef;
}

sub Navimow_RefreshToken($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	## remove all other request timers do avoid double requests or invalid requests
	RemoveInternalTimer($hash, 'Navimow_Request');
	readingsSingleUpdate($hash, 'polling', 'inactiv', 1 );
	
	## check if refresh-token exists
	my $r_token = $hash->{helper}{REFRESH_TOKEN};
	if (!defined($r_token)) {
		readingsSingleUpdate($hash, 'token_status', 'failed: no refresh-token', 1 );
		return 'Navimow (RefreshToken): No Refresh-Token saved! Do a Navimow Cloud Login (OAuth2) first!' 
	};

	HttpUtils_NonblockingGet(
	{
		callback => \&Navimow_CallbackGetToken,
		method => 'POST',
		hash => $hash,
		url => $navimow_token_url,
		timeout => 10,
		data => 
		{
			grant_type => 'refresh_token', 
			client_id => $hash->{CLIENT_ID},
			client_secret => $hash->{CLIENT_SECRET},
			refresh_token => $r_token,
		}
	});
	Log3($name, 5, "$name (RefreshToken): request for TokenRefresh");
	readingsSingleUpdate($hash, 'token_status', 'request for TokenRefresh ..', 1 );
	
	## set new timer for update-request only for safety if refresh fails
	Navimow_Polltimer($hash);
	
	return undef;
}

sub Navimow_Set($$@)
{
	my ($hash, $name, @a) = @_;
	return undef if not scalar @a;
	my $cmd = shift @a;
	my $value = join(' ', @a);
	my $setlist = '';
	
	my $iomaster = $modules{Navimow}{defptr}{IOMASTER};
	## set for IOMASTER
	if ( defined($iomaster) && ($hash eq $iomaster)) {
		if ( lc($cmd) eq 'authcode') {
		return Navimow_GetToken($hash, $value);
		
		} elsif ( lc($cmd) eq 'connectmqtt') {
			return Navimow_MQTT_Connect($hash);
		
		} elsif ( lc($cmd) eq 'disconnectmqtt') {
			return Navimow_MQTT_Disconnect($hash, 0);
		
		} else {
			$setlist = 'AuthCode connectMQTT:noArg disconnectMQTT:noArg';
		}
	## set for mow units	
	} else {
		my $sn = $hash->{DEF} // '';
		return "No serial number of device to command!" if ($sn eq '');
		
		if ($cmd =~ m/start|stop|pause|resume|dock/ ) {
		
			my $data = '{"commands":[{"devices":[{"id":"'.$sn.'"}],"execution": {"command":"action.devices.commands.';
			if ($cmd eq 'start')    { $data.= 'StartStop","params":{"on":true}}}]}';} 
			elsif ($cmd eq 'stop')  { $data.= 'StartStop","params":{"on":false}}}]}';}
			elsif ($cmd eq 'pause') { $data.= 'PauseUnpause","params":{"on":false}}}]}';} 
			elsif ($cmd eq 'resume'){ $data.= 'PauseUnpause","params":{"on":true}}}]}';} 
			elsif ($cmd eq 'dock')  { $data.= 'Dock","params":null}}]}';} 
			else  {$data='';}
			return "Error creating command!" if ($data eq '' );
			readingsSingleUpdate($hash, 'set_data', $data, 1 ) if (AttrVal($name,'saveRawData',undef));
			readingsSingleUpdate($hash, 'set_cmd', $cmd, 1 );
			Log3($name, 5, "$name (Set_Cmd): $cmd = $data");
			Navimow_Request($hash, 'POST', '/openapi/smarthome/sendCommands', $data);
		} else {
			$setlist = 'start:noArg stop:noArg pause:noArg resume:noArg dock:noArg';			
		}
	}
	return "unknown argument $cmd , choose one of $setlist" if ($setlist ne '');
}

sub Navimow_Polltimer($;$) 
{
	my ($hash, $interval) = @_;
	my $name = $hash->{NAME};
	RemoveInternalTimer($hash, 'Navimow_Request');
	$interval = $hash->{INTERVAL} if !(defined($interval));
	Log3($name, 5, "$name (Polltimer): Schedule next request in $interval seconds");
	if (defined($interval) && ($interval>0 )) {
		readingsSingleUpdate($hash, 'polling', 'activ', 1 );
		InternalTimer(gettimeofday()+$interval, 'Navimow_Request', $hash, 0);
	} else {
		readingsSingleUpdate($hash, 'polling', 'inactive', 1 );
	}
}


sub Navimow_Request($;$$$)
{
	my ($hashdevice, $method, $path, $data) = @_;
	
	## make sure that all devices are loaded first in $modules{Navimow}{defptr}
	if (!$init_done) {
		InternalTimer(gettimeofday()+1, 'Navimow_Request', $hashdevice, 0);
		return;
	} 	
	
	## start UpdateRequest always as IOMASTER, because there is the tokenSet 
	my $hash = $modules{Navimow}{defptr}{IOMASTER};
	return 'Navimow (UpdateRequest): No IOMASTER device found! ' if (!defined($hash));
	my $name = $hash->{NAME};
	
	
	my $a_token = $hash->{helper}{ACCESS_TOKEN};
	if (!defined($a_token)) {
		readingsSingleUpdate($hash, 'token_status', 'no valid access-token', 1);
		readingsSingleUpdate($hash, 'polling', 'inactiv', 1 );
		my $r_token = $hash->{helper}{REFRESH_TOKEN};
		if (!defined($r_token)) {
			readingsSingleUpdate($hash, 'token_status', 'no refresh-token available', 1);
			Log3($name, 2, "$name (Request): no access-token or refresh-token available");
			return 'Navimow (Set-Cmd): No TokenSet found! ' ;			
		}		
		Navimow_RefreshToken($hash);
		return 'Navimow (Set-Cmd): Refreshing access-token ...';
	}
	
	my $uuid4 = Navimow_UUID();
	
	## first get all mower devices once
	if (!defined($hash->{AUTHLIST})) {
		$hash->{AUTHLIST} = 1;
		$method = 'GET';
		$path = '/openapi/smarthome/authList';
		Log3($name, 4, "$name (Request): Requesting for available devices first.");
		
	## second get mqtt-credentials once	
	} elsif (!defined($hash->{MQTTCREDENTIALS})) {
		$hash->{MQTTCREDENTIALS} = 1;
		$method = 'GET';
		$path = '/openapi/mqtt/userInfo/get/v2';
		Log3($name, 4, "$name (Request): Requesting for mqtt-credentials frist.");
	} 
	
	if ( !defined($method) || !defined($path) ){
		$method = 'POST';
		$path = '/openapi/smarthome/getVehicleStatus';
		$data = '{"devices": [';
		foreach my $sn (sort keys %{$modules{Navimow}{defptr}}) {
			$data .= '{"id":"'.$sn.'"},' if ($sn ne 'IOMASTER');
		}
		return "No serial number of devices. First define mower devices!" if ($data eq '{"devices": [');
		$data = substr($data, 0, -1);
		$data .= ']}';
		Log3($name, 5, "$name (Request): request VehicleStatus for the following devices: $data");
	} 
	
	HttpUtils_NonblockingGet(
	{ 	
		callback => \&Navimow_Response,
		method => $method,
		hash => $hash,
		url => $navimow_cloud_url.$path, 
		timeout => 5, 
		data => $data,
		header =>		
		{
			'Authorization' => 'Bearer '.$a_token,
			'Content-Type' => 'application/json',
			'requestId' => $uuid4
		}
	});
	readingsSingleUpdate($hash, 'update_response', 'request for UpdateData ..', 1 );
	## schedule next regular polling in 6 seconds (after timeout) when only asked for sn or credentials
	Navimow_Polltimer($hash,($method eq 'GET' )? 6: undef);
	
	return undef;	
}

sub Navimow_Get($$@)
{
	my ($hash, $name, @a) = @_;
	return undef if not scalar @a;
	my $cmd = shift(@a);
	my $setlist = '';

	my $iomaster = $modules{Navimow}{defptr}{IOMASTER};
	
	## get for IOMASTER
	if ( defined($iomaster) && ($hash eq $iomaster)) {
		if ( lc($cmd) eq 'refreshtoken') {
			return Navimow_RefreshToken($hash);
			
		} elsif ( lc($cmd) eq 'devices') {
			return Navimow_Request($hash, 'GET', '/openapi/smarthome/authList');
	
		} elsif ( lc($cmd) eq 'devicestatus') {
			return Navimow_Request($hash);
	
		} elsif ( lc($cmd) eq 'mqtt-credentials') {
			return Navimow_Request($hash, 'GET', '/openapi/mqtt/userInfo/get/v2');
	
		} else {
			$setlist='refreshToken:noArg devices:noArg devicestatus:noArg mqtt-credentials:noArg';
		}
		
	## get for mow units
	} else {
		if ( lc($cmd) eq 'devicestatus') {
			return Navimow_Request($hash);	
		} else {
			$setlist='devicestatus:noArg';
		}
	}	
	return "unknown argument $cmd, choose one of $setlist" if ($setlist ne '');
	return undef;
}

sub Navimow_Attr($$$;$)
{
	my ($cmd, $name, $attrName, $attrVal) = @_;
	my $hash = $defs{$name};
	
	my $iomaster = $modules{Navimow}{defptr}{IOMASTER};
	
	if ( defined($iomaster) && $hash eq $iomaster ) { 
	## handle the change of IOMASTER attributes
		if ( $attrName eq 'interval' ) {
			if ( $cmd eq 'del' || $attrVal == 0) {
				$hash->{INTERVAL} = 0;
				Navimow_Polltimer($hash, 0);
			} elsif ( $attrVal >= 60 ) {
				$hash->{INTERVAL} = $attrVal;
				Navimow_Polltimer($hash, 1);
			} else { ## if interval < 60
				return "Minimum polling interval is 60 seconds.";
			}
		## save jsonRawData in a reading
		} elsif ( $attrName eq 'saveRawData' ) {
			if (( $cmd eq 'del' ) || ( $attrVal == 0 )) {
				CommandDeleteReading(undef,'-q '.$name.' jsonRawData.*');
				CommandDeleteReading(undef,'-q '.$name.' mqtt_downlink_vehicle.*');
			}
		} elsif ( $attrName eq 'MQTT' ) {
			if (( $cmd eq 'del' ) || ( $attrVal == 0 )) {
				Navimow_MQTT_Disconnect($hash, 0);
			} elsif ( $attrVal == 1 ) {
				## first complete the attribut-change, then start Navimow_MQTT_Connect
				InternalTimer(gettimeofday() + 1, 'Navimow_MQTT_Connect', $hash, 0);
			}
		}		
	}
	return undef;
}

## --> Parameter $sn kürzen ?!?

sub Navimow_GetDetail($$$)
{
	my ($hash,$data,$rdg) = @_;
	
	## if Hash -> go deeper in the next level
	if (ref($data) eq "HASH") {
		foreach my $skey (sort keys %{$data}) {
			my $srdg = ($rdg eq '' ) ? $skey : $rdg.'_'.$skey;
			$srdg = '._data' if ($skey eq 'data');
			$srdg = '' if ($skey eq 'payload');
			Navimow_GetDetail($hash,$data->{$skey},$srdg);
		}
		
	## if array -> go for all entrys
	} elsif (ref($data) eq "ARRAY") {
		foreach my $mp (sort keys @{$data}) {
			if ((ref($data->[$mp]) eq "HASH" ) && (defined($data->[$mp]{id}))) { 
				my $sn = $data->[$mp]{id};
				my $defptr = $modules{Navimow}{defptr}{$sn};
				## if not defined -> check if autocreate is set -> then define device
				if (!defined($defptr)) {
					my $name = $hash->{NAME};
					Log3($name, 3, "$name (GetDetail): New device detected with serial number = $sn");
					if (AttrVal($hash->{NAME},'autocreate',undef)) {
						my $dev_name = $data->[$mp]{name} // '';
						$dev_name =~ s/[^A-Za-z0-9_]/_/g;
						$dev_name .= '_'.$sn;
						Log3($name, 3, "$name (GetDetail): Autocreating $dev_name");
						my $define = "$dev_name Navimow $sn";
						if ( my $cmdret = CommandDefine(undef,$define) ) {
							Log3($name, 1, "$name (GetDetail): An error occurred while creating device for $sn: $cmdret ");
						} 
						$defptr = $modules{Navimow}{defptr}{$sn};						
					}
				}
				## if device now exists in FHEM, parse the data and create readings	
				if (defined($defptr)) {
					$defptr->{VERSION} = $Navimow_version;
					readingsBeginUpdate($defptr);
					Navimow_GetDetail($defptr,$data->[$mp],'');
					readingsEndUpdate($defptr, 1);					
				}
			} else {
				Navimow_GetDetail($hash,$data->[$mp],$rdg);
			}
			
		}
	## if no hash and no array -> get info
	} else {
		## fix vehicleState HTTP=string <> MQTT=integer
## toDo reverse-engineering of integer vehicleState to string
		$rdg.= '_Num' if ($rdg eq 'vehicleState' && $data =~ m/^\d+$/);
		readingsBulkUpdate($hash, $rdg, $data);
	}
}

sub Navimow_Transformdata($$)
{
	my ($hash, $txt) = @_;
	my $data;
	my $name = $hash->{NAME};
	
	## transform json to perl object -> use JSON::XS (=fastest), otherwise use an own awesome method
	if ($json_xs_available) {
		$data = eval { JSON::XS->new->boolean_values("false","true")->decode($txt) };
		if ($@) {
			Log3($name, 2, $name.' (Transformdata): Error using JSON::XS. To use the faster JSON::XS you have to update to the latest version. Try: "sudo apt-get install -y libjson-xs-perl" in the linux shell. Currently an alternative method will be used.');
			$json_xs_available = 0;
		};
	}
	if (!$json_xs_available) {
		$txt =~ s/"\s*:\s*true/":"true"/g; 
		$txt =~ s/"\s*:\s*false/":"false"/g;
		$txt =~ s/([,:\[])\s*(null)/$1"$2"/g;		
		$txt =~ s/":/"=>/g;
		($data) = eval $txt ;
	}
	return $data;	
}


sub Navimow_Response
{
	my ($param, $err, $txt) = @_;
	my $hash = $param->{hash};
	my $name = $hash->{NAME};
	$hash->{VERSION} = $Navimow_version;

	if ( $err || $param->{code} != 200 ) { 
		my $errortext = 'Navimow (CallbackUpdateRequest) failed: ';
		if ($err) {
			$errortext .= $err ;
		} else {
			$errortext .= "HTTP-Status-Code=" . $param->{code} if (defined($param->{code}));
			$errortext .= " Response: " . $txt if (defined($txt));
		}
		Log3($name, 2, "$name (Response): $errortext");
		readingsSingleUpdate($hash, 'update_response', $errortext , 1 );
		if (defined($param->{code}) && $param->{code} == 401 ){
			delete $hash->{helper}{ACCESS_TOKEN} if (defined($hash->{helper}) && defined($hash->{helper}{ACCESS_TOKEN}));
		}			
		return;
	}
	
	readingsSingleUpdate($hash, 'jsonRawData', $txt , 1 ) if (AttrVal($name,'saveRawData',undef));
	Log3($name, 5, "$name (Response): $txt");	
	my $data = Navimow_Transformdata($hash, $txt);
	
	readingsBeginUpdate($hash); 
	Navimow_GetDetail($hash,$data,"") if (defined($data));
	readingsBulkUpdate($hash, 'update_response', $json_xs_available?'JSON_XS':'JSON_EVAL');
	readingsEndUpdate($hash, 1);
}

#####################################################################################################
################################################## MQTT #############################################
#####################################################################################################

sub Navimow_MQTT_Connect($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	return 'Enable attribut MQTT=1 first' if (!AttrVal($name, 'MQTT', 0));
		
	my $host = ReadingsVal($name, '._data_mqttHost', '');
	my $path = ReadingsVal($name, '._data_mqttUrl', ''); 
	
	readingsSingleUpdate($hash, 'mqtt_connect', 'no mqtt-credentials', 1) if (!$host || !$path );
			
	if (!$init_done || !$host || !$path ) {
		InternalTimer(gettimeofday()+30, 'Navimow_MQTT_Connect', $hash, 0);
		return;
	} 
	
	if ($host =~ m,^(wss:)/*([^/:]+)$,) {
		$host = $1.$2.":443";
	} else {
		return 'Error in mqtt_host';
	}
	$hash->{DeviceName} = $host.$path; 
	$hash->{binary} = 1;
    $hash->{header}{"Sec-WebSocket-Protocol"} = "mqtt";
	$hash->{header}{"requestId"} = Navimow_UUID();
	## ggf. nochmal prüfen, ob ACCESS_TOKEN hier benötigt wird !
	if (defined($hash->{helper}{ACCESS_TOKEN})) {
		$hash->{header}{"Authorization"} = "Bearer ".$hash->{helper}{ACCESS_TOKEN};
	};
	
	$hash->{BUF} = "";	 
	
	if (defined($hash->{FD})) {
		readingsSingleUpdate($hash, 'mqtt_connect', 'closing device', 1);
		DevIo_SimpleWrite($hash, "\xe0\x00", 0); ## = "DISCONNECT"
		DevIo_CloseDev($hash);
	}
	readingsSingleUpdate($hash, 'mqtt_connect', 'connection request for websocket', 1);
	Log3($name, 5, "$name (MQTT_Connect): request Websocket-connection $hash->{DeviceName}");
	return DevIo_OpenDev($hash, 0, "Navimow_MQTT_Login", sub(){});	
}

sub Navimow_LengthPlusPayload($) 
{ 
    my ($data) = @_;
    my $v = length $data;
    my $o = "";
    my $d;
    do {
        $d = $v % 128;
        $v = int($v/128);
        $d |= 0x80 if $v;
        $o .= pack "C", $d;
    } while $d & 0x80;
    return "$o$data";
}

sub Navimow_MQTT_Login($)
{
	my ($hash) = @_;	
	my $name = $hash->{NAME};
	
	my $user = ReadingsVal($name, '._data_userName', '');
	my $pwd  = ReadingsVal($name, '._data_pwdInfo', '');
	if (!$user || !$pwd) {
		readingsSingleUpdate($hash, 'mqtt_connect', 'no user/password for mqtt', 1);
		return 'Navimow (MQTT_Login): No username or password found! '; 
	}
	
	my $clientid = "web_".$user."_".substr($hash->{helper}{secret_state},0,10);
	my $flags = 0xc2; ## 0x02 + 0x80 + 0x40 for clean session, user, password
	
	my $msg = "\x10" . Navimow_LengthPlusPayload(pack(
        "x C/a* C C n n/a* n/a* n/a*",
        #Protokoll Version Flags   keepalive clientid   username password
		"MQIsdp",  3,      $flags, 60,       $clientid,	$user,   $pwd 
    ));
	readingsSingleUpdate($hash, 'mqtt_connect', 'login for mqtt connection', 1);
	Log3($name, 5, "$name (MQTT_Login): Login as user $user and password **** (clientid=$clientid)");
	DevIo_SimpleWrite($hash, $msg, 0);
	Navimow_MQTT_Keepalive($hash);
}

sub Navimow_MQTT_Read($)
{
	my ($hash) = @_;	
	my $name = $hash->{NAME};
	my $buf = DevIo_SimpleRead($hash);
	
	return Navimow_MQTT_Disconnect($hash, 1) if(!defined($buf));
	
	$hash->{BUF} .= $buf;
	return if (length($hash->{BUF}) < 2); # not enough data yet
	
	my $len = 0;
	my $mul = 1;
	my $off = 1;
	my $byte;
	
	## 1.Byte: Flags (Bits 0–3) 0=retain, 1=qos, 2=qos, 3=retain
	## 1.Byte: Control Packet Type (Bits 4–7)
	## 2.Byte: Remaining Length: 7 Datenbits pro Byte
	## 2.Byte: Remaining Length: 1 Datenbit für weiteres Byte Remaining Length (max. 4 Byte Length)
		
	do {
		return Navimow_MQTT_Disconnect($hash, 1) if ($off > 4); ## error: malformed remaining length
		$byte = ord(substr($hash->{BUF},$off++,1));
		$len += ($byte & 0x7f) * $mul;
		$mul *= 128;
		return if ( $len + $off > length($hash->{BUF}));      ## not enough data yet
	} while ( $byte & 0x80 );
	
	my $qos  = (ord(substr($hash->{BUF},0,1)) & 0x06) >> 1;
	my $type = (ord(substr($hash->{BUF},0,1)) & 0xF0) >> 4;
	my $data = substr($hash->{BUF},$off,$len);	
	$hash->{BUF} = substr($hash->{BUF},$len+$off);
	
	if ($type == 2) {
		## 2 => "CONNACK" -> Check return code
		## Byte 1 of data: Connect Acknowledge Flags
		## Byte 2 of data: Connect Return code
		my $returncode = ord(substr($data,1,1));
		my @txt = ("connection accepted","unacceptable protocol version","identifier rejected", 
					"server unavailable","bad user name or password","not authorized");
		readingsSingleUpdate($hash, 'mqtt_connect', $txt[$returncode], 1) if ($returncode <= int(@txt));
		if ($returncode) {
			Log3($name, 2, "$name (MQTT-Login-Error):".($returncode<= int(@txt))? $txt[$returncode]: "unknown error");
			Navimow_MQTT_Disconnect($hash, 0);
			return;
		}
		
		## subscribe for topics matching serialnumber
		my @topics = ();
		foreach my $sn (sort keys %{$modules{Navimow}{defptr}}) {
			 if ($sn ne 'IOMASTER') {
				push(@topics, "/downlink/vehicle/$sn/realtimeDate/state");
				push(@topics, "/downlink/vehicle/$sn/realtimeDate/event");
				push(@topics, "/downlink/vehicle/$sn/realtimeDate/attributes");
				push(@topics, "/downlink/vehicle/$sn/realtimeDate/location");
			 }
		}
		return "No serial number of device. First get devices!" if (int(@topics) == 0);
	
		## \x82 = SUBSCRIBE + QoS ## n (2 Byte) = packet identifier ## n/a* = topics ## x = QoS 0
		my $msg = "\x82". Navimow_LengthPlusPayload( pack("n", $hash->{FD}) . pack("(n/a* x)*", @topics)); 
		DevIo_SimpleWrite($hash, $msg, 0);
		readingsSingleUpdate($hash, 'mqtt_subscribe', 'subscribe waiting for ack', 1);
		
	} elsif ($type == 3) {
		##  3 => "PUBLISH" -> wenn qos
		my ($topic, $pid, $msg) = "";
		if ($qos) {
			($topic, $pid, $msg) = unpack("n/a n a*", $data);
		} else {
			($topic, $msg) = unpack("n/a a*", $data);
		}
		if($unicodeEncoding) {
			$topic = Encode::decode('UTF-8', $topic);
			$msg = Encode::decode('UTF-8', $msg);
		}
		DevIo_SimpleWrite($hash, "\x40\x02".pack("n", $pid), 0) if($qos); # PUBACK
		
		
		my ($sn) = ( $topic =~ m,^/downlink/vehicle/([^/]*)/,);
		$topic =~ s,/,_,g;
		Log3($name, 5, "$name (MQTT_Read): $topic : $msg");
		readingsSingleUpdate($hash, 'mqtt'.$topic, $msg, 1) if (AttrVal($hash->{NAME},'saveRawData',undef));
		
		## no serial number in topic?
		return if (!defined($sn));
		## payload to short?
		return if (length($msg) < 5);
		
		my $defptr = $modules{Navimow}{defptr}{$sn};
		if (defined($defptr)) {
			my $json = Navimow_Transformdata($hash, $msg);
			if (defined($json)) {
				readingsBeginUpdate($defptr);
				Navimow_GetDetail($defptr,$json,'');
				readingsEndUpdate($defptr, 1);				
			}				
		}		
		
	} elsif ($type == 9) {
		##  9 => "SUBACK" -> subscribe successful
		Log3($name, 5, "$name (MQTT_Read): subscribe successful");
		readingsSingleUpdate($hash, 'mqtt_subscribe', 'subscribe successful', 1);
		
	} elsif ($type == 13) {
		## 13 => "PINGRESP" -> keepalive successful
		Log3($name, 5, "$name (MQTT_Read): PINGRESP for PINGREQ received.");
		delete($hash->{PINGREQ});		
		readingsSingleUpdate($hash, 'mqtt_keepalive', 'alive', 1);
		
	} else {
		## unhandled packet
		Log3($name, 2, "$name (MQTT_Read): Unhandled packet-type no. $type data : $data");
	}		
}

sub Navimow_MQTT_Disconnect($$)
{
	my ($hash, $reconnect) = @_;
	
	RemoveInternalTimer($hash, "Navimow_MQTT_Keepalive");
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, 'mqtt_connect', 'disconnected' );
	readingsBulkUpdate($hash, 'mqtt_keepalive', 'disconnected' );
	readingsBulkUpdate($hash, 'mqtt_subscribe', 'disconnected' );
	readingsEndUpdate($hash, 1);
		
	if (defined($hash->{FD})) {
		DevIo_SimpleWrite($hash, "\xe0\x00", 0); ## = "DISCONNECT"
		DevIo_CloseDev($hash);
	}
	if (AttrVal($hash->{NAME}, 'MQTT', 0) && $reconnect ) {
		InternalTimer(gettimeofday() + 30, 'Navimow_MQTT_Connect', $hash, 0)
	}
}

sub Navimow_MQTT_Keepalive($)
{
	my ($hash) = @_;
		
	if (defined($hash->{PINGREQ})){
		my $name = $hash->{NAME};
		Log3($name, 2, "$name (MQTT_Keepalive): No PINGRESP for last PINGREQ");
		delete($hash->{PINGREQ});
		Navimow_MQTT_Disconnect($hash, 1);
		return;
	}
	return if (!AttrVal($hash->{NAME}, 'MQTT', 0));
	DevIo_SimpleWrite($hash, "\xc0\x00", 0); ## = "PINGREQ"
	$hash->{PINGREQ} = TimeNow();
	InternalTimer(gettimeofday()+60, "Navimow_MQTT_Keepalive", $hash, 0);	
}


1;

=pod
=item device
=item summary    Cloud connection for segway navimow devices (mower) 
=item summary_DE Cloud-Anbindung fuer Segway Navimow Geraete (Maehroboter) 
=begin html

<a id="Navimow"></a>
<h3>Navimow</h3>
<ul>
  This module can receive data from Navimow-Mower over the Segway-cloud. It can 
  also send simple commands.
  <br><br>
  <a id="Navimow-define"></a>
  <b>Define</b>
  <ul>
    <ul>
      <br>
      First a master device (bridge) has to be defined to handle the access  
      to thecloud:<br><br>
      <b><u>Definition of the master device</u></b><br><br>
      <code>define &lt;NAME NAVIMOW_BRIDGE&gt; Navimow</code><br>
	  or with individuel config-parameters:
	  <code>define &lt;NAME NAVIMOW_BRIDGE&gt; Navimow &lt;CLIENT_ID&gt; 
      &lt;CLIENT_SECRET&gt; &lt;REDIRECT_URI&gt;</code><br>
      <br>
	  CLIENT_ID und CLIENT_SECRET are actually adopted from home-assistant.
	  <br>
      <br>
      Of course you can also define an individual REDIRECT_URI by the following scheme:
      <br><br>
      https://&lt;IP FHEM&gt;:8083/fhem?cmd.Test=set%20NAVIMOW%5FBRIDGE%20AuthCode%20
      <br><br> 
      This REDIRECT_URI must contain the host that you set yourself in the browser for 
      access FHEM, usually the IP address of the FHEM server. This is intended to send 
      the authorization code as a command via FHEMWEB API be transferred to the defined 
	  master device (here e.g. NAVIMOW_BRIDGE). <br>
	  When using the csrfToken in FHEM, a static token must be used and 
      appended to the REDIRECT_URI (&fwcsrf=myToken123). 
      <br><br>
      Since the individual definition is more complex and presents various pitfalls, 
      especially when using security functions such as csrfToken or access 
      restrictions in FHEM, I would recommed to rookies to use the generic REDIRECT_URI 
      http://localhost/callback instead.
      <br><br>
      After the master device has been created, a Navimow cloud login (OAuth2) is 
      required. The individual link is stored in the internals (Internal 
      AUTHORIZATION_LINK). After you logged in, you will be redirected to the REDIRECT_URI. 
      If you have configured an individual REDIRECT_URI for FHEM, the authorization code is 
      automatically passed to FHEM. If this doesn't work, check your REDIRECT_URI 
      or use the generic REDIRECT_URI given above. When using the generic REDIRECT_URI: 
      You have to copy the complete redirect-link of the website from the browser
      (http://localhost/callback?code=xxxxxxxxxxxx) to the clipboard. 
      Then enter the following command in FHEM:<br><br>
      <code>set &lt;NAME NAVIMOW_BRIDGE&gt; AuthCode &lt;complete link of return URL&gt;
      </code><br><br>
      This completes the setup of the master device.<br><br>
      <b><u>Definition of the mower units</u></b><br><br>
      Thereafter for each mower unit one device has to be defined. It is 
      easiest to let the devices be autocreated (see attributes). Otherwise 
      they can also be created manually if the serial number is known:<br><br>
      <code>define &lt;NAME&gt; Navimow &lt;SERIAL NUMBER&gt;</code><br>
    </ul>
  </ul>
  <br>
  <b>Set</b>
  <ul>
    <ul>
      <br>
      <a id="Navimow-set-AuthCode"></a>
      <li><b>AuthCode</b><br>
        The Navimow-Cloud-Login (OAuth2) returns a temporary authorization-code 
        to get the access-token and a refresh-token. If the automatic process 
        fails, you can set the authorization-code (=return of the redirect-uri) 
        manually.
      </li>
      <a id="Navimow-set-connectMQTT"></a>
      <li><b>connectMQTT</b><br>
        Establishes a connection to the MQTT server to receive live data (location).
      </li>
	  <br>
      <a id="Navimow-set-disconnectMQTT"></a>
      <li><b>disconnectMQTT</b><br>
        Terminates the connection to the MQTT server.
      </li>	  
    </ul>
    Currently, only simple control via the API is possible:<br>
    <br>
    <ul>
      <a id="Navimow-set-start"></a>
      <li><b>start</b><br>
       Starts the mower. Selecting a zone is currently not possible. 
      </li>
      <a id="Navimow-set-stop"></a>
      <li><b>stop</b><br>
        Stops the mower and ends the task.
      </li>
      <a id="Navimow-set-pause"></a>
      <li><b>pause</b><br>
        Stops the mower and pauses the task.
      </li>
	  <a id="Navimow-set-resume"></a>
      <li><b>resume</b><br>
        Restart the mower and resume the task
      </li>
	  <a id="Navimow-set-dock"></a>
      <li><b>dock</b><br>
        Send the mower to the charging station.
      </li>
    </ul>
  </ul>
  <br>
  <b>Get</b> 
  <ul>
    <ul>
      <br>
      <a id="Navimow-get-refreshToken"></a>
      <li><b>refreshToken</b><br>
        The access token is normally valid for 3,600 seconds. However, it can 
        be renewed. This process is usually triggered automatically before the 
        validity period expires. A manual renewal can also be initiated using 
        this command.
      </li>
	  <a id="Navimow-get-devices"></a>
      <li><b>devices</b><br>
        Generates an immediate request to the cloud to retrieve the registered 
        mowers and their serial numbers. If the autocreate attribute is set to 
        1, the corresponding devices are automatically created in FHEM.
      </li>
      <a id="Navimow-get-devicestatus"></a>
      <li><b>devicestatus</b><br>
        Generates an immediate request to the cloud to retrieve the current 
        data for all devices defined in FHEM.
      </li>
      <a id="Navimow-get-mqtt-credentials"></a>
      <li><b>mqtt-credentials</b><br>
        Generates an immediate request to the cloud to obtain the required 
        access credentials for the MQTT server.
      </li>
    </ul>
  </ul>
  <br>
  <b>Attributes</b> (only for the master device)<br>
  <ul>
    <ul>
      <br>
      <a id="Navimow-attr-autocreate"></a>
      <li><b>autocreate</b> [ 1 | 0 ]<br>
        When set to 1 (default), new devices are automatically created 
        when corresponding data is received from the cloud. 
        Set this value to 0 or delete it to disable the 
        automatic creation of devices.
        <br>
      </li>
      <a id="Navimow-attr-interval"></a>
      <li><b>interval</b> [ 0 | 60 .. &infin; ]<br>
        Defines the interval in seconds at which current data is to be 
        retrieved from the cloud via an HTTP request. The minimum is 60 
        seconds to keep server load low. The default is 900 seconds. If 
        the attribute is set to 0, automatic retrieval is disabled. This 
        attribute is available only on the master device.
        <br>
      </li>
	  <a id="Navimow-attr-MQTT"></a>
      <li><b>MQTT</b> [ 1 | 0 ]<br>
        When set to 1 (default), a connection to the MQTT server is 
        established alongside the HTTP request to enable the receipt of 
        live data; if the attribute is set to 0, the connection to the 
        MQTT server is disabled. This attribute is available only on the 
        master device.
        <br>
      </li>
	  <a id="Navimow-attr-saveRawData"></a>
      <li><b>saveRawData</b> [ 0 | 1 ]<br>
        When set to 1 (default = 0), the received data is stored in raw 
        format (JSON string) in the `saveRawData` reading. This is 
        primarily intended for debugging or troubleshooting purposes. 
        This attribute is available only on the master device.
        <br>
      </li>
    </ul>
  </ul>
</ul>
<br>

=end html
=begin html_DE

<a id="Navimow"></a>
<h3>Navimow</h3>
<ul>
  Dieses Modul kann Daten von Navimow-Robotern (Segway) empfangen und Befehle zum 
  Steuern senden.
  <br><br>
  <a id="Navimow-define"></a>
  <b>Define</b>
  <ul>
    <ul>
      <br>
      Zuerst muss ein Master-Device (bzw. eine Bridge) definiert werden, 
      welches den Zugriff auf die Cloud erm&ouml;glicht:<br><br>
      <b><u>Definition des Master-Devices</u></b><br><br>
	  <code>define &lt;NAME NAVIMOW_BRIDGE&gt; Navimow</code><br><br>
	  oder mit individuell vorhandenen Konfigurationsdaten:<br><br>
      <code>define &lt;NAME NAVIMOW_BRIDGE&gt; Navimow &lt;CLIENT_ID&gt; 
      &lt;CLIENT_SECRET&gt; &lt;REDIRECT_URI&gt;</code><br><br>
      CLIENT_ID und CLIENT_SECRET werden aktuell von der Schnittstelle f&uuml; 
      home-assistant adaptiert (vgl. https://github.com/segwaynavimow/NavimowHA ).
	  <br><br>
      Es besteht auch die M&ouml;glichkeit, eine individuelle REDIRECT_URI für 
      FHEM zu definieren. Diese muss nach folgendem Schema erstellt bzw. definiert werden:
      <br><br>
      <code>https://&lt;IP FHEM&gt;:8083/fhem?cmd.Test=set%20NAVIMOW%5FBRIDGE%20AuthCode%20</code>
      <br><br>
      Diese REDIRECT_URI muss den Host enthalten, den man selbst im Browser für den 
      Zugriff auf FHEM verwendet, also in der Regel die IP-Adresse des FHEM-Servers. 
      Damit soll &uuml;ber die WEB-API von FHEM der Authorisierungscode als Kommando 
      in das definierte Master-Device (hier z.B. NAVIMOW_BRIDGE) &uuml;bergeben werden. 
      Bei Benutzung des csrfToken in FHEM, muss ein statisches Token verwendet werden 
	  und dieses an die REDIRECT_URI angehangen werden (&fwcsrf=myToken123).
      <br><br>
      Da die individuelle Definition aufw&auml;ndiger und insbesondere bei Verwendung 
      von Sicherheitsfunktion wie csrfToken oder Zugriffsbeschr&auml;nkungen in FHEM 
      verschiedene Fallstricke bereit h&auml;lt, kann stattdessen 
      <code>http://localhost/callback</code> als REDIRECT_URI verwendet werden.
      <br><br>
      Nachdem das Master-Device angelegt worden ist, ist ein Navimow-Cloud-Login (OAuth2) 
      erforderlich. Der individuelle Link ist in den Internals gespeichert 
      (Internal AUTHORIZATION_LINK). Ihr werdet auf die Seite von Segway geleitet, 
      m&uuml;sst euch dort einloggen. Anschliessend werdet ihr auf die REDIRECT_URI 
	  weitergeleitet.
      <br><br>
      Wenn ihr eine individuelle REDIRECT_URI für FHEM konfiguriert habt, wird der 
      Authorisierungscode automatisch an FHEM &uuml;bergeben. Wenn dies nicht funktioniert, 
      &uuml;berpr&uuml;ft eure REDIRECT_URI oder verwendet die oben angegebene allgemeime 
      REDIRECT_URI<code>http://localhost/callback</code>. In diesem muss der komplette Link der 
	  Internetseite aus dem Browser (http://localhost/callback?code=xxxxxxxxxxxx) 
      in die Zwischenablage kopiert und in FHEM als set-command eingegeben werden:<br><br>
      <code>set &lt;NAME NAVIMOW_BRIDGE&gt; AuthCode &lt;kompletter Link der R&uuml;ckgabe-URL&gt;
      </code><br><br>
      Damit ist die Einrichtung des Master-Device abgeschlossen.<br><br>
      <b><u>Definition der Mower</u></b>
      <br><br>
      Danach ist f&uuml;r jeden Mower ein Device zu definieren. 
      Es ist am einfachsten, die Devices automatisch erstellen zu lassen 
      (siehe Attribute). Ansonsten k&ouml;nnen sie auch manuell erstellt 
      werden, wenn die Seriennummer bereits bekannt ist:<br><br>
      <code>define &lt;NAME&gt; Navimow &lt;SERIENNUMMER&gt;</code><br>
    </ul>
  </ul>
  <br>
  <b>Set</b>
  <ul>
    <ul>
      <br>
      <a id="Navimow-set-AuthCode"></a>
      <li><b>AuthCode</b><br>
        Der Navimow-Cloud-Login (OAuth2) gibt einen tempor&auml;ren 
        Autorisierungscode zur&uuml;ck. Falls der automatische Prozess 
        scheitert, kann der Autorisierungscode (= R&uuml;ckgabe an die 
        redirect-uri) auch manuell gesetzt werden.
      </li>
      <br>
      <a id="Navimow-set-connectMQTT"></a>
      <li><b>connectMQTT</b><br>
        Stellt eine Verbindung zum MQTT-Server, um Live-Daten (location) zu 
		erhalten.
      </li>
      <br>
      <a id="Navimow-set-disconnectMQTT"></a>
      <li><b>disconnectMQTT</b><br>
        Beendet die Verbindung zum MQTT-Server.
      </li>
	  <br>
    </ul>
    Aktuell ist nur eine einfache Steuerung &uuml;ber die API m&ouml;glich:<br>
    <br>
    <ul>
      <a id="Navimow-set-start"></a>
      <li><b>start</b><br>
        Startet den Mower. Eine Auswahl der Zone ist aktuell nicht m&ouml;glich. 
      </li>
      <a id="Navimow-set-stop"></a>
      <li><b>stop</b><br>
        H&auml;lt den Mower bzw. stoppt die Arbeitsaufgabe.
      </li>
      <a id="Navimow-set-pause"></a>
      <li><b>pause</b><br>
        H&auml;lt den Mower an und pausiert die Arbeitsaufgabe.
      </li>
	  <a id="Navimow-set-resume"></a>
      <li><b>resume</b><br>
        Startet den Mower wieder und f&uuml;hrt die Arbeitsaufgabe fort.
      </li>
	  <a id="Navimow-set-dock"></a>
      <li><b>dock</b><br>
        Schickt den Mower zur Ladestation.
      </li>
    </ul>
  </ul>
  <br>
  <b>Get</b>
  <ul>
    <ul>
      <br>
      <a id="Navimow-get-refreshToken"></a>
      <li><b>refreshToken</b><br>
        Der Access-Token ist normalerweise 3600 Sekunden g&uuml;tig. Er kann 
        aber erneuert werden. Dies wird normalerweise automatisch vor Ablauf 
        der G&uuml;tigkeitsdauer veranlasst. Mit diesem Befehl kann auch eine 
        manuelle Erneuerung angesto&szlig;en werden.
      </li>
	  <a id="Navimow-get-devices"></a>
      <li><b>devices</b><br>
        Erzeugt eine sofortige HTTP-Anfrage an die Cloud, um die registrierten 
        Mower und ihre Seriennummer zu erhalten. Wenn das Attribut autocreate 
        mit 1 definiert ist, werden die entsprechenden Ger&auml;te automatisch 
        in FHEM angelegt.
      </li>
      <a id="Navimow-get-devicestatus"></a>
      <li><b>devicestatus</b><br>
        Erzeugt eine sofortige HTTP-Anfrage an die Cloud, um die aktuellen Daten  
        aller in FHEM definierten Ger&auml;te zu erhalten.
      </li>
      <a id="Navimow-get-mqtt-credentials"></a>
      <li><b>mqtt-credentials</b><br>
        Erzeugt eine sofortige HTTP-Anfrage an die Cloud, um die erforderlichen 
		Zugangsdaten f&uuml;r dem MQTT-Server zu bekommen.
      </li>
    </ul>
  </ul>
  <br>
  <b>Attributes</b> (nur f&uuml;r das Master-Device)<br>
  <ul>
    <ul>
      <br>
      <a id="Navimow-attr-autocreate"></a>
      <li><b>autocreate</b> [ 1 | 0 ]<br>
        Bei Einstellung auf 1 (Standard) werden neue Devices automatisch 
        erstellt, wenn entsprechende Daten aus der Cloud empfangen werden. 
        Setzen Sie diesen Wert auf 0 oder l&ouml;schen ihn, um die 
        automatische Erstellung von Devices zu deaktivieren. 
        <br>
      </li>
      <a id="Navimow-attr-interval"></a>
      <li><b>interval</b> [ 0 | 60 .. &infin; ]<br>
        Definiert das Intervall in Sekunden, innerhalb dessen die aktuellen 
        Daten aus der Cloud jeweils &uuml;ber einen HTTP-Request abgefragt 
		werden sollen. Das Minimum betr&auml;gt 60 Sekunden, um die Serverlast
        gering zu halten. Standard sind 900 Sekunden. Wenn das Attribut auf 0 
		gesetzt wird, wird der automatisierte Abruf deaktiviert. Dieses Attribut 
		ist nur im Master-Device verf&uuml;gbar.<br>
      </li>
	  <a id="Navimow-attr-MQTT"></a>
      <li><b>MQTT</b> [ 1 | 0 ]<br>
        Bei Einstellung auf 1 (Standard), wird neben den HTTP-Request eine 
        Verbidnung zum MQTT-Server aufgebaut, um Live-Daten empfangen zu
        k&ouml;nnen; Wenn das Attribut auf 0 gesetzt wird, wird die Verbindung 
        zum MQTT-Server deaktiviert. Dieses Attribut ist nur im Master-Device 
        verf&uuml;gbar.<br>
      </li>
	  <a id="Navimow-attr-saveRawData"></a>
      <li><b>saveRawData</b> [ 0 | 1 ]<br>
        Bei Einstellung auf 1 (Standard = 0), werden die empfangenen Daten 
        im Roh-Format (Json-String) im Reading saveRawData gespeichert. Dies
        soll vorrangig dem debugging bzw. der Fehlersuche dienen. Dieses 
        Attribut ist nur im Master-Device verf&uuml;gbar.<br>
      </li>
    </ul>
  </ul>
  <br>
</ul>
<br>

=end html_DE

=cut