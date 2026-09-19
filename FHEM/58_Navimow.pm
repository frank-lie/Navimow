#######################################################################################################
#
# 58_Navimow.pm 
#
# This modul ist used for control of Segway Navimow.
#
#######################################################################################################
# v0.0.3 - 31.08.2026 Commands start, stop, pause, resume, dock over Rest-API
# v0.0.2 - 30.07.2026 Get data from json
# v0.0.1 - 22.06.2026 Basic Oauth
#######################################################################################################

package main;

use strict;
use warnings;

use Time::HiRes qw(gettimeofday time);
use HttpUtils;
use SetExtensions;

use vars qw(%FW_webArgs);

## try to use JSON::XS, otherwise use own decoding sub
my $json_xs_available = 1;
eval "use JSON::XS qw(decode_json); 1" or $json_xs_available = 0;

my $Navimow_version = 'v0.0.3 - 31.08.2026';

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

sub Navimow_Set($$$$);				# handle the set commands of devices
sub Navimow_Get($$@);				# handle the get commands of devices
sub Navimow_Attr($$);				# handle the change of attributes

sub Navimow_Request($;$$$);			# get/post a request
sub Navimow_Response;				# receive data from the cloud

sub Navimow_GetDetail($$$$);		# parse json

#######################################################################################################

sub Navimow_Initialize($)
{
	my ($hash) = @_;
	$hash->{DefFn}    = 'Navimow_Define';
	$hash->{UndefFn}  = 'Navimow_Undefine';
	$hash->{SetFn}    = 'Navimow_Set';
	$hash->{GetFn}    = 'Navimow_Get';
	$hash->{AttrFn}   = 'Navimow_Attr';
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
	
	$hash->{INTERVAL} = 900;
	$hash->{VERSION} = $Navimow_version;
	$hash->{helper}{secret_state} = Navimow_CreateSecretState();
	
	$hash->{CLIENT_ID}     = defined($a[2]) ? $a[2] : 'homeassistant';
	$hash->{CLIENT_SECRET} = defined($a[3]) ? $a[3] : '57056e15-722e-42be-bbaa-b0cbfb208a52';
	$hash->{REDIRECT_URI}  = defined($a[4]) ? $a[4] : 'http://localhost:1/callback';
	
	$hash->{DEF} = $hash->{CLIENT_ID}.' '.$hash->{CLIENT_SECRET}.' '.$hash->{REDIRECT_URI};
		
	$hash->{AUTHORIZATION_LINK} = "<html><b><a href=\"".$navimow_oauth_url.#"authorize?".
			"&response_type=code".
			"&client_id=".$hash->{CLIENT_ID}.
			"&redirect_uri=".urlEncode($hash->{REDIRECT_URI}).
			"&state=".$hash->{helper}{secret_state}.
			"\" target=\"_blank\">Segway Navimow Login (OAuth2)</a></b> ".
			"</html>";
		
	my (undef, $r_token) = getKeyValue('Navimow_refresh_token');
	
	if (defined($r_token)) {
		$hash->{helper}{REFRESH_TOKEN} = $r_token;
		Log3 $name, 2, 'Navimow (Define at start): Refresh-Token ready to use.';
	} else {
		## else delete old tokens
		delete $hash->{helper}{ACCESS_TOKEN} if (defined($hash->{helper}) && defined($hash->{helper}{ACCESS_TOKEN}));
		delete $hash->{helper}{REFRESH_TOKEN} if (defined($hash->{helper}) && defined($hash->{helper}{REFRESH_TOKEN}));
	}
		 
	setDevAttrList($name, 'interval saveRawData:1,0 '. $readingFnAttributes);
	if ($init_done) {
		CommandAttr(undef, '-silent '.$name.' interval 900') if(!AttrVal($name,"interval",""));
		CommandAttr(undef, '-silent '.$name.' event-on-change-reading .*') if(!AttrVal($name,"event-on-change-reading",""));
	}
	return undef;
}

sub Navimow_Undefine($$)
{
	my ($hash, $arg) = @_;
	setKeyValue('Navimow_refresh_token',undef);
	RemoveInternalTimer($hash);
	return undef;
}

sub Navimow_CallbackGetToken
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
		
	if ( $err || $param->{code} != 200 ) { 
		my $errortext = 'Navimow (CallbackGetToken) failed: ';
		if ($err) {
			$errortext .= $err ;
		} else {
			$errortext .= "HTTP-Status-Code=" . $param->{code} if (defined($param->{code}));
			$errortext .= " Response: " . $data if (defined($data));
		}
		Log3 $hash, 2, $errortext;
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
		Log3 $hash, 2, "Navimow (CallbackGetToken): No TokenSet found";
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
	
	Log3 $hash, 4, 'Navimow (CallbackGetToken): TokenSet successfully stored' ;
	
	## do automatic request for available devices
	Navimow_Request($hash, 'GET', '/openapi/smarthome/authList');
	
	## schedule Request if polling is activated
	my $interval = $hash->{INTERVAL};
	if (defined($interval) && ($interval>0 )) {
		readingsSingleUpdate($hash, 'state', 'polling activ', 1 );
		RemoveInternalTimer($hash,'Navimow_Request');
		## schedule first request in 6 sec (after request of available devices)
		InternalTimer(gettimeofday()+6, 'Navimow_Request', $hash, 0);
	}		
	## do automatic refresh token 1 minute before expired
    InternalTimer(gettimeofday()+ReadingsNum($hash->{NAME},'expires_in',3600)-60,'Navimow_RefreshToken',$hash,0);
	
}

sub Navimow_GetToken($$)
{
	my ($hash, $code) = @_;	

	$code = urlDecode($code);
	$code = $1 if ($code =~ m/code=([^&]*)/);
	
	if (length($code)<8) {
		$code = $FW_webArgs{"code"} if defined($FW_webArgs{"code"});
		return "No valid AuthCode" if (length($code)<8);
	}	
	
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
	return;
}

sub Navimow_RefreshToken($)
{
	my ($hash) = @_;	
		
	## remove all other timers do avoid double requests or invalid requests
	RemoveInternalTimer($hash);
	readingsSingleUpdate($hash, 'state', 'polling inactiv', 1 );
	
	## check if refresh-token exists
	my $r_token = $hash->{helper}{REFRESH_TOKEN};
	return 'Navimow (RefreshToken): No Refresh-Token saved! Do a Navimow Cloud Login (OAuth2) first!' if (!defined($r_token));

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
	readingsSingleUpdate($hash, 'token_status', 'request for TokenRefresh ..', 1 );
	
	## set new timer for update-request only for safety if refresh fails
	my $interval = $hash->{INTERVAL};
	if (defined($interval) && ($interval>0 )) {
		readingsSingleUpdate($hash, 'state', 'polling activ', 1 );
		InternalTimer(gettimeofday()+$interval, 'Navimow_Request', $hash, 0);
	}	
	return;
}

sub Navimow_Set($$$$)
{
	my ($hash, $name, @a) = @_;
	return undef if not scalar @a;
	my $cmd = shift @a;
	my $value = join(' ', @a);
	my $setlist = '';
	
	if ( lc($cmd) eq 'authcode') {
		return Navimow_GetToken($hash, $value);
	} elsif ( lc($cmd) eq 'command') {
		my $sn = $a[1] // ReadingsVal($name, 'device0_id', '');
		return "No serial number of device to command!" if ($sn eq '');
		
		my $action = $a[0] // '';
		return "Allowed commands are only: start, stop, pause, resume, dock!" if !($action =~ m/start|stop|pause|resume|dock/ );
		
		my $data = '{"commands":[{"devices":[{"id":"'.$sn.'"}],"execution": {"command":"action.devices.commands.';
		if ($action eq 'start')    { $data.= 'StartStop","params":{"on":true}}}]}';} 
		elsif ($action eq 'stop')  { $data.= 'StartStop","params":{"on":false}}}]}';}
		elsif ($action eq 'pause') { $data.= 'PauseUnpause","params":{"on":false}}}]}';} 
		elsif ($action eq 'resume'){ $data.= 'PauseUnpause","params":{"on":true}}}]}';} 
		elsif ($action eq 'dock')  { $data.= 'Dock","params":null}}]}';} 
		else  {$data='';}
		return "Error creating command!" if ($data eq '' );
		
		readingsSingleUpdate($hash, 'set_data', $data, 1 );
		Navimow_Request($hash, 'POST', '/openapi/smarthome/sendCommands', $data);	
			
	} else  {
		$setlist = 'AuthCode Command:start,stop,pause,resume,dock';
		return "unknown argument $cmd : $value, choose one of $setlist";
	}
}

sub Navimow_Request($;$$$)
{
	my ($hash, $method, $path, $data) = @_;
	
	if (!$init_done) {
		InternalTimer(gettimeofday()+1, 'Navimow_Request', $hash, 0);
		return;
	}
	
	my $a_token = $hash->{helper}{ACCESS_TOKEN};
	if (!defined($a_token)) {
		readingsSingleUpdate($hash, 'state', 'no access-token', 1);
		my $r_token = $hash->{helper}{REFRESH_TOKEN};
		return 'Navimow (Set-Cmd): No TokenSet found! ' if (!defined($r_token));
		Navimow_RefreshToken($hash);
		return 'Navimow (Set-Cmd): Refreshing access-token ...';
	}
	RemoveInternalTimer($hash,'Navimow_Request');
	
	my $uuid4 = Navimow_UUID();
		
	if ( !defined($method) || !defined($path) ){
		$method = 'POST';
		$path = '/openapi/smarthome/getVehicleStatus' ;
	}
	my $body = "";
	if ( $method eq 'POST' && (!defined($data) || $data eq '')) {
		my $sn = ReadingsVal($hash->{NAME}, 'device0_id', '');
		return "No serial number of device. First get devices!" if ($sn eq '');
		$body = '{"devices": [{"id":"'.$sn.'"}]}';
	} else {
		$body=$data;
	}
	
	HttpUtils_NonblockingGet(
	{ 	
		callback => \&Navimow_Response,
		method => $method,
		hash => $hash,
		url => $navimow_cloud_url.$path, 
		timeout => 5, 
		data => $body,
		header =>		
		{
			'Authorization' => 'Bearer '.$a_token,
			'Content-Type' => 'application/json',
			'requestId' => $uuid4
		}
	});
	readingsSingleUpdate($hash, 'update_response', 'request for UpdateData ..', 1 );
	
	my $interval = $hash->{INTERVAL};
	if (defined($interval) && ($interval>0 )) {
		readingsSingleUpdate($hash, 'state', 'polling activ', 1 );
		InternalTimer(gettimeofday()+$interval, 'Navimow_Request', $hash, 0);
	} else {
		readingsSingleUpdate($hash, 'state', 'polling inactive', 1 );
	}
	return;	
}

sub Navimow_Get($$@)
{
	my ($hash, $name, @a) = @_;
	return undef if not scalar @a;
	my $cmd = shift(@a);
	my $setlist = '';

	if ( lc($cmd) eq 'refreshtoken') {
		return Navimow_RefreshToken($hash);
			
	} elsif ( lc($cmd) eq 'forceupdate') {
		return Navimow_Request($hash);
	
	} elsif ( lc($cmd) eq 'devices') {
		return Navimow_Request($hash, 'GET', '/openapi/smarthome/authList');
	
	} elsif ( lc($cmd) eq 'devicestatus') {
		return Navimow_Request($hash, 'POST', '/openapi/smarthome/getVehicleStatus');
	
	} elsif ( lc($cmd) eq 'mqtt-credentials') {
		return Navimow_Request($hash, 'GET', '/openapi/mqtt/userInfo/get/v2');
	
	} else {
		$setlist='forceUpdate:noArg refreshToken:noArg devices:noArg devicestatus:noArg mqtt-credentials:noArg';
	}
	
	return "unknown argument $cmd, choose one of $setlist" if ($setlist ne '');
	return undef;
}

sub Navimow_Attr($$)
{
	my ($cmd, $name, $attrName, $attrVal) = @_;
	my $hash = $defs{$name};
	
	if ( $attrName eq 'interval' ) {
		if ( $cmd eq 'del' || $attrVal == 0) {
			$hash->{INTERVAL} = 0;
			RemoveInternalTimer($hash,'Navimow_Request');
			readingsSingleUpdate($hash, 'state', 'polling inactive', 1 );
		} elsif ( AttrVal($name,'allow-short-intervals',0) || $attrVal >= 60 ) {
			$hash->{INTERVAL} = $attrVal;
			RemoveInternalTimer($hash,'Navimow_Request');
			InternalTimer(gettimeofday()+1, 'Navimow_Request', $hash, 0);
		} else { ## if interval < 60
			return "Minimum polling interval is 60 seconds.";
		}
	## save jsonRawData in a reading
	} elsif ( $attrName eq 'saveRawData' ) {
		if (( $cmd eq 'del' ) || ( $attrVal == 0 )) {
			CommandDeleteReading(undef,'-q '.$name.' jsonRawData.*');
		}
	}			
	return undef;
}

## --> Parameter $sn kürzen ?!?

sub Navimow_GetDetail($$$$)
{
	my ($hash,$data,$rdg,$sn) = @_;
	
	foreach my $skey (sort keys %{$data}) {
		
		## if Hash -> go deeper in the next level
		if (ref($data->{$skey}) eq "HASH") {
				Navimow_GetDetail($hash,$data->{$skey},$skey,$sn);
		
		## if array -> go for all entrys		
		} elsif (ref($data->{$skey}) eq "ARRAY"){
			foreach my $mp (sort keys @{$data->{$skey}}) {
			    if (ref($data->{$skey}[$mp]) eq "HASH") {
					$sn = (defined($data->{$skey}[$mp]{id}))? $data->{$skey}[$mp]{id} : $mp; 
					Navimow_GetDetail($hash,$data->{$skey}[$mp],($skey eq 'devices')?'device'.$mp:$rdg.'_'.$skey,$sn); 
				} 
			}
			
		## if no hash and no array -> get info
		} else {
			readingsBulkUpdate($hash, $rdg.'_'.$skey, $data->{$skey});			
		}	
	}
}

sub Navimow_Response 
{
	my ($param, $err, $data) = @_;
	my $hash = $param->{hash};
	$hash->{VERSION} = $Navimow_version;

	if ( $err || $param->{code} != 200 ) { 
		my $errortext = 'Navimow (CallbackUpdateRequest) failed: ';
		if ($err) {
			$errortext .= $err ;
		} else {
			$errortext .= "HTTP-Status-Code=" . $param->{code} if (defined($param->{code}));
			$errortext .= " Response: " . $data if (defined($data));
		}
		Log3 $hash, 2, $errortext;
		readingsSingleUpdate($hash, 'update_response', $errortext , 1 );
		if (defined($param->{code}) && $param->{code} == 401 ){
			delete $hash->{helper}{ACCESS_TOKEN} if (defined($hash->{helper}) && defined($hash->{helper}{ACCESS_TOKEN}));
		}			
		return;
	}
	
	if (AttrVal($hash->{NAME},'saveRawData',undef)) {
		readingsSingleUpdate($hash, 'jsonRawData', $data , 1 );
	}
	
	my $cdda;
	
	## transform json to perl object -> use JSON::XS (=fastest), otherwise use an own awesome method
	if ($json_xs_available) {
		$cdda = eval { JSON::XS->new->boolean_values("false","true")->decode($data) };
		if ($@) {
			Log3 $hash, 2, 'Error using JSON::XS. To use the faster JSON::XS you have to update to the latest version. Try: "sudo apt-get install -y libjson-xs-perl" in the linux shell. Currently an alternative method will be used.';
			$json_xs_available = 0;
		};
	}
	if (!$json_xs_available) {
		$data =~ s/"\s*:\s*true/":"true"/g; 
		$data =~ s/"\s*:\s*false/":"false"/g;
		$data =~ s/([,:\[])\s*(null)/$1"$2"/g;		
		$data =~ s/":/"=>/g;
		($cdda) = eval $data ;
	}
	
	readingsBeginUpdate($hash); 
	Navimow_GetDetail($hash,$cdda,"","") if (defined($cdda) && ref($cdda) eq "HASH");
	readingsBulkUpdate($hash, 'update_response', $json_xs_available?'JSON_XS':'EVAL');
	readingsEndUpdate($hash, 1);
	}

1;
