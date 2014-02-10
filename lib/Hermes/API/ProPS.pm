# Hermes::API::ProPS - Hermes API ProPS shipping module
#
# Copyright 2010,2011 by Stefan Hornburg (Racke) <racke@linuxia.de>

package Hermes::API::ProPS;

use strict;
use warnings;

use Log::Dispatch;

use Locale::Geocode;
use SOAP::Lite;

use DateTime;
use IO::File;
use MIME::Base64     'decode_base64';

our $VERSION = '0.1500';

my $wsse = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd";
my $wsu  = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd";
my $ns_hermes = "http://hermes_api.service.hlg.de"; # tns2 for the child of body tag( the soap operation name

our %parms = (
	# Hermes::API authentication
	PartnerId      => undef,
	PartnerPwd     => undef,
	PartnerToken   => undef,
	UserToken      => undef,

	# Module parameters
	SandBox        => 0,
	SandBoxHost    => 'hermesapisbx.hlg.de',	# sandboxapi.hlg.de
	ProductionHost => 'hermesapi.hlg.de',	# hermesapi2.hlg.de
	APIVersion     => '1.5',			# 1.3

	# Debug/logging
	Trace          => undef,
 );

sub new( $@ ) {( bless {}, shift )->initialize( @_ ) }

sub initialize( @ )
{
	my ($self, @args) = @_;

	# defaults
	defined $parms{$_} and $self->{$_} = $parms{$_}
		for keys %parms;

	# check for required parameters: PartnerId and PartnerPwd
	while ( @args )
	{
		my ($key, $value) = (shift @args, shift @args);
		$self->{$key} = $value if exists $parms{$key};
	}

	unless ( defined $self->{PartnerId} && defined $self->{PartnerPwd} ) {
		die "PartnerId and PartnerPwd parameters required for Hermes::API::ProPS objects.\n";
	}

	# defaults
	defined $parms{$_} && ($self->{$_} = $parms{$_})
		for keys %parms;

	# log dispatcher
	$self->{log} = new Log::Dispatch( outputs => [['Screen', min_level => 'debug']] );

	# finally build URL
	my $url =
	$self->{url} = $self->build_url();

	# instantiate SOAP::Lite
	my $soap =
	$self->{soap} = new SOAP::Lite( proxy => $url )->uri( $ns_hermes );
	$soap->on_action( sub { qq( "$_[1]" ) } );
	$soap->autotype( 0 );

	if ( $self->{Trace} ) {
		my $request_sub = sub {$self->log_request( @_ )};
		$self->{soap}->import( +trace => [transport => $request_sub] );
	}

	$self;
}

sub url               { shift->{url} }
sub CheckAvailability { shift->ProPS( 'propsCheckAvailability' ) }

sub UserLogin( $$ )
{
	my ($self, $username, $password) = @_;

	my @credentials = ( benutzername => $username, kennwort => $password );
	my $soap_params = $self->soap_parameters( [login => \@credentials] );

	my $ret = $self->ProPS(propsUserLogin => $soap_params)
		or return;

	# set user token for further requests
	$self->{UserToken} = $ret;
}

sub OrderSave( $% )
{
	my ($self, $address, %extra) = @_;
	my $soap_params = $self->order_parameters( $address, %extra );
	$self->ProPS( propsOrderSave => $soap_params );
}

sub OrderDelete( $ )
{
	my ($self, $order_number) = @_;

	$self->{UserToken}
		or die "UserToken required for OrderDelete service.\n";

	my $order_no = {value => $order_number, type => 'string'};
	my $soap_params  = $self->soap_parameters( [orderNo => $order_no] );
	$self->ProPS( propsOrderDelete => $soap_params );
}

sub GetOrder( % )
{
	my ($self, %parms) = @_;

	$self->{UserToken}
		or die "UserToken required for GetOrder service.\n";

	my $input_params =
	[	orderNo    => {value => $parms{orderNo},    type => 'string'}
	,	shippingId => {value => $parms{shippingId}, type => 'string'}
	];

	$self->ProPS( propsGetPropsOrder => $self->soap_parameters( $input_params ) );
}

sub GetOrders
{
	my ($self, $search) = @_;

	$self->{UserToken}
		or die "UserToken required for GetOrders service.\n";

	my $soap_params = $self->search_parameters( $search );
	my $ret = $self->ProPS( propsGetPropsOrders => $soap_params )
		or return;

	my $orders = $ret->{orders}{PropsOrderShort};

	! defined $orders
		? return[] # no matches
		: ref $orders eq 'HASH'
			? return [$orders]   # single answer
			: $orders;
}

sub PrintLabel( $$$$ )
{
	my ($self, $order_number, $format, $position, $output) = @_;

	$self->{UserToken}
		or die "UserToken required for GetOrders service.\n";

	my ($service, $input_params, $output_param);
	if ( $format eq 'PDF' )
	{
		$service      = 'propsOrderPrintLabelPdf';
		$input_params =
		[	orderNo => {value => $order_number, type => 'string'}
		,	position =>( $position || 1 )
		];
		$output_param = 'pdfData';
	}
	elsif ( $format eq 'JPEG' )
	{
		$service      = 'propsOrderPrintLabelJpeg';
		$input_params = [orderNo => {value => $order_number, type=> 'string'}];
		$output_param = 'jpegData';
	}

	my $soap_params = $self->soap_parameters( $input_params );

	my $ret = $self->ProPS( $service, $soap_params )
		or return;

	if ( $output )
	{
		my $fh = IO::File->new( $output, 'w' );
		print $fh decode_base64 $ret->{$output_param};
		$fh->close;
	}
	$ret->{$output_param};
}

sub CollectionRequest( $% )
{
	my ($self, $date, %parcel_counts) = @_;

	$self->{UserToken}
		or die "UserToken required for CollectionRequest service.\n";

	my @request_parms = (collectionDate => $date);

	foreach( qw/XS S M L XL XXL/ )
	{
		push @request_parms, "numberOfParcelsClass_$_" =>( $parcel_counts{$_} || 0 );
	}

	$self->ProPS( propsCollectionRequest => $self->soap_parameters( [collectionOrder => \@request_parms] ) );
}

sub CollectionCancel {
     my ($self, $date) = @_;

     $self->{UserToken}
        or die "UserToken required for CollectionCancel service.\n";

     my $soap_params = $self->soap_parameters( [collectionDate => $date] );
     $self->ProPS( propsCollectionCancel => $soap_params );
}

sub GetCollectionOrders( $$$ )
{
	my ($self, $date_from, $date_to, $large) = @_;

	$self->{UserToken}
		or die "UserToken required for GetOrders service.\n";

	$date_from ||= DateTime->now->iso8601;
	$date_to   ||= DateTime->now->add( months => 3 )->iso8601;
	defined $large or $large = 0;

	my $soap_params = $self->soap_parameters(
		[	collectionDateFrom => $date_from,
		,	collectionDateTo   => $date_to,
		,	onlyMoreThan2ccm   => $large
		]
	);

	my $ret = $self->ProPS( propsGetCollectionOrders => $soap_params )
		or return;

	my $orders = $ret->{orders}{PropsCollectionOrderLong};

	!defined $orders
		? return []
		: ref $orders eq 'HASH'
			? return [$orders]  # single answer is hash
			: $orders;
}

sub ReadShipmentStatus( $ )
{
	my ($self, $shipid) = @_;

	my $soap_params = $self->soap_parameters( [
		shippingId => { value => $shipid, type => 'string' }
	] );

	$self->ProPS( propsReadShipmentStatus => $soap_params );
}

sub ProductInformation { shift->ProPS( 'propsProductlnformation' ) }

sub ListOfProductsATG()
{
	my ($self) = @_;
	$self->{UserToken}
		or die "UserToken required for ListOfProductsATG service.\n";

	$self->ProPS( 'propsListOfProductsATG' );
}

sub ProPS
{
	my ($self, $service, @params) = @_;

	# modify service:make it a soap data object
	$service  = SOAP::Data->new(
		name => $service,
		prefix => 'ha',
		uri => $ns_hermes
	 );

	# build SOAP headers
	my @headers = $self->soap_header;

	# this one works - only sets thens on the soapaction tag( in the body )
	# XXX temp disabled $self->{soap}->ns( $ns_hermes );#->prefix( 'h' );

	#$self->{soap}->uri( $ns_hermes );#->prefix( 'h' );

	my $ret = $self->{soap}->call( $service, @params, @headers );
	die $@ if $@;  # XXX where's the eval?

	if ( $ret->fault )
	{
		my $detail = $ret->faultdetail
			or die 'SOAP Fault: '.$ret->faultcode.'( '.$ret->faultstring." )";

		# check for service exception
		if ( my $item = $detail->{ServiceException}{exceptionItems}{ExceptionItem} )
		{
			$self->set_error( $item );
			return;
		}
		print Dumper $detail;
	}
	else
	{
		$self->clear_error;
	}

	# pick up PartnerToken from response header
	$self->{PartnerToken} = $ret->header->{PartnerToken}
		if ( ref $ret->header eq 'HASH' );
	$ret->result;
}

sub search_parameters( $ )
{
	my ($self, $search) = @_;
	my ($input, @search_parms);

	# country code conversion
	$search->{countryCode} = $self->country_alpha3( $search->{countryCode} )
		if ref $search eq 'HASH' && exists $search->{countryCode};

	my %address_parms = (lastname => 1, city => 1);

	for( qw/orderNo identNo from to lastname city postcode
		countryCode clientReferenceNumber ebayNumber status/ )
	{
		#defined $search->{$_} && $search->{$_} =~ /\S/ or next;

		push @search_parms, defined $address_parms{$_}
			# force type to "string" in order to avoid base64 encoding
			?( $_ => {value => $search->{$_}, type => 'string'} )
			:( $_ => $search->{$_} );
	}

	$self->soap_parameters( [searchCriteria => \@search_parms] );
}

sub order_parameters
{
	my ($self, $address, %extra) = @_;

	# country code conversion
	$address->{countryCode} = $self->country_alpha3( $address->{countryCode} );

	my @address_parms;
	for( qw/firstname lastname street houseNumber addressAdd postcode
		city district countryCode email telephoneNumber telephonePrefix/ )
	{
		exists $address->{$_} && $address->{$_} =~ /\S/ or next;
		# force type to "string" in order to avoid base64 encoding
		push @address_parms, $_ => {value => $address->{$_}, type => 'string'};
	}

	my @order_parms = ( receiver => \@address_parms );
	foreach( qw/orderNo clientReferenceNumber parcelClass
		amountCashOnDelivery includeCashOnDelivery/ )
	{
		push @order_parms, $_ => $extra{$_}
			if exists $extra{$_};
	}

	$self->soap_parameters( [propsOrder => \@order_parms] );
}

sub country_alpha3( $ )
{
	my ($self, $code) = @_;
	$code && length( $code )==2
		or return $code;

	my $lc  = Locale::Geocode->new;
	my $lct = $lc->lookup( $code )
		or die "Invalid country code $code\n";

	$lct->alpha3;
}

sub build_url( )
{
	my ($self) = @_;

	my $version_part = $self->{APIVersion};
	$version_part    =~ s/\.//g;

	my $host = $self->{SandBox}
		? $self->{SandBoxHost}
		: $self->{ProductionHost};

	"https://$host/hermes-api-props-web/services/v${version_part}/ProPS";#?wsdl";
}

sub soap_header
{
	my ($self) = @_;
	my @headers;

#	foreach( qw/PartnerId PartnerPwd PartnerToken UserToken/ )
#	{
#		exists $self->{$_} or next;
#		push @headers, SOAP::Header->name( $_ )->value( $self->{$_} )
#	}

	my $user  = SOAP::Data->name( Username => $self->{PartnerId} );
	my $pwd   = SOAP::Data->name( Password => $self->{PartnerPwd} );
	$pwd->attr( { Type => "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordText" } );

	$_->prefix( 'wsse' )->type( '' ) for $user, $pwd;

	my $token = SOAP::Data->new
	(	name   => 'UsernameToken'
	,	prefix => 'wsse' # 'wsse'
	,	value  => \SOAP::Data->value( $user, $pwd )
	);

	$token->attr( { 'wsu:Id' => 'UsernameToken-1' } );

	my $sec   = SOAP::Header->new
	(	name   => 'Security'
	,	uri    => $wsse
	,	prefix => 'wsse'
	,	value  => \$token
	);

	$sec->attr( { 'xmlns:wsu' => $wsu } );


	$sec = SOAP::Header->name(
		"Security" => \SOAP::Header->value(
			SOAP::Data->name(
				"UsernameToken" => \SOAP::Data->value( $user, $pwd )
			 )
			->attr( {'wsu:Id' => 'UsernameToken-1' } )
			->prefix( 'wsse' )
		 )
	)
	->uri( $wsse )->prefix( 'wsse' )
	->attr( {'xmlns:wsu'=>$wsu} );

	$sec->mustUnderstand( 1 );

	push @headers, $sec;

	if ( my $ut = $self->{UserToken} )
	{
		push @headers, SOAP::Header->name( 'UserToken' )->value( $ut )
			# NOT taken care of by default_ns
			->uri( $ns_hermes )
			->prefix( 'her' )
		;
	}

	@headers;
}

sub soap_parameters( $$$ )
{
	my ($self, $input, $level) = @_;
	$level ||= 0;

	my @input = @$input;
	if ( @input > 2 && $level == 0 )
	{
		# build XML string and pass to SOAP::Data
		no warnings 'uninitialized';
		my $xml;
		while ( @input )
		{
			my ($key, $value) = ( shift @input, shift @input );
			defined $value or next;

			$xml .= ref $value eq 'HASH'
				? qq{<$key>$value->{value}</$key>}
				: qq{<$key>$value</$key>};
		}
		return SOAP::Data->type( xml => $xml );
	}

	my @params;
	while ( @input )
	{
		my ($key, $value) = (shift @input, shift @input);
		push @params
			, ref $value eq 'ARRAY'
			? SOAP::Data->name( $key => $self->soap_parameters( $value, $level+1 ) )
			: ref $value eq 'HASH' # forcing SOAP type
			? SOAP::Data->name( $key => $value->{value} )->type( $value->{type} )
			: SOAP::Data->name( $key => $value );
	}

	$level ? \SOAP::Data->value( @params ) : $params[0];
}

# error handling
sub set_error	{ shift->{error} = shift }

sub clear_error	{ delete shift->{error}  }

sub get_error
{
	my ($self) = @_;
	my @err = ref $self->{error} eq 'ARRAY' ? @{$self->{error}} :$self->{error};
	@err ? join( "\n", map {$_->{errorMessage}} @err ) : "No error defined";
}

sub log_request
{
	my ($self, $in) = @_;
	$self->{log}->debug( $in->as_string )
		if $in->isa( "HTTP::Message" );
}

1;
