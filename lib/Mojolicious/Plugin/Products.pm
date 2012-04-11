#----------------------------------------------------------------------
# copyright (C) 1999-2005 Mitel
#----------------------------------------------------------------------

package Mitel::AMC::Products;

#use strict;
use Exporter;

use esmith::db;
use esmith::Broker;
use esmith::Broker::tallies;
use Data::Dumper;

use Mitel::AMC::Constant qw( :status :account );

=pod

=head1 NAME

Mitel::AMC::Products

=head1 SYNOPSIS

use Mitel::AMC::Products;

=head1 DESCRIPTION

- Provides a wrapper into the database-subsystem for describing
product bundles

=head1 Exported Functions

=cut

BEGIN
{
}

my $REGEXPRenlistBundleCode = 'RE(_|-)*ENLIST';

=item B<get_bundle_details>

Using the provided bundle code, it looks up the various properties
and rules associated with this bundle and stores them into a data
structure for passing around between subroutines.

=cut

# TODO: Complete ERR handling for mandatory product fields
sub get_bundle_details {

    my $bundle_code = shift;
    my $partner_id  = shift;

    my %system_services        = _get_service_details();
    my %system_tags            = _get_tag_details();
    my %license_based_services = _get_license_services();
    my %blade_based_tags       = _get_blade_tags();
    my %tally2systype_tags_restrictions = _get_tally_to_systype_tags_restrictions();

    my %bundle_data = (
        error     => 0,
        error_cnt => 0,
        error_msg => undef,
    );

    # [bundles]
    my $sql_bundle = qq(
		SELECT
			b.*,
			b2sl.sap_product_id
		FROM
			bundles AS b
				LEFT JOIN bundle_to_sap_lookup AS b2sl
					ON b.bundle_code = b2sl.bundle_code
		WHERE
			b.bundle_code = ?
	);

    my $sth_bundle = loadNocQuerySth( $sql_bundle, $bundle_code );

    if ( my $record_bundle = $sth_bundle->fetchrow_hashref ) {
        $bundle_data{properties}{code}       = $record_bundle->{bundle_code};
        $bundle_data{properties}{desc}       = $record_bundle->{bundle_desc};
        $bundle_data{properties}{active}     = $record_bundle->{active};
        $bundle_data{properties}{pay_period} = $record_bundle->{pay_period};
        $bundle_data{properties}{part_number} = $record_bundle->{sap_product_id};
        $bundle_data{properties}{product_model_version} = $record_bundle->{product_model_version};
    } else {
        $bundle_data{error} = 1;
        $bundle_data{error_msg}{ $bundle_data{error_cnt} } = "No such bundle: $bundle_code.";
        $bundle_data{error_cnt}++;

        return %bundle_data;
    }

    unless ( defined $bundle_data{properties}{part_number} ) {
        $bundle_data{error} = 1;
        $bundle_data{error_msg}{ $bundle_data{error_cnt} } = "Missing SAP part number.";
        $bundle_data{error_cnt}++;
    }

    if (_is_part_number_duplicated( $bundle_data{properties}{code},$bundle_data{properties}{part_number})) {
        $bundle_data{error} = 1;
        $bundle_data{error_msg}{ $bundle_data{error_cnt} } = "Duplicate/already active part number.";
        $bundle_data{error_cnt}++;
    }

    # [bundle_to_sap_swa_pn_override]
    my $swa_override = undef;

    my $sql_swa_override = qq(
		SELECT
			swa_pn_equivalent
		FROM
			bundle_to_sap_swa_pn_override
		WHERE
			bundle_code = ?
	);

    my $sth_swa_override = loadNocQuerySth( $sql_swa_override, $bundle_code );

    if ( my $rec_swa_override = $sth_swa_override->fetchrow_hashref ) {
        $swa_override = $rec_swa_override->{'swa_pn_equivalent'};
    }

    $bundle_data{properties}{swa_part_number_override} = $swa_override;

    # [bundle_rules]
    #
    #	PROPERTIES:
    #	- bundle group (BUNDLE_GROUP)
    #	- bundle type (BUNDLE_TYPE)
    #	- delivers server role (SERVER_ROLE)
    #	- delivers server type (SERVER_TYPE)
    #	- display order (RELATIVE_DISPLAY_ORDER)
    #	- application order (RELATIVE_APPLICATION_ORDER)
    #	- expiration rules (EXPIRES)
    #	- delivers revocable on assign (REVOCABLE)
    #	- allows for multiple BASE kits [either direction] (ALLOW_MULTI_BASE)
    #	- process order from sap / ghost product (AMC_PROCESS)
    #	- removes tags on assign (REMOVE_TAGS)
    #	- removes services on assign (REMOVE_SERVICES)
    #	- changes the app_record type on assign (OVERRIDE_SERVER_TYPE)
    #
    #	RULES:
    #	- requires active service (REQUIRES_ACTIVE_SERVICE)
    #	- requires active tag(s) (REQUIRES_ACTIVE_TAG)
    #	- max uses per server (MAX_USES)
    #	- tally range (RANGE_DEPENDANT_TALLY, TALLY_RANGE_{LOWER,UPPER}_BOUND)

    my $sql_bundle_rules = qq(
		SELECT
			rule_name,
			rule_data
		FROM
			bundle_rules
		WHERE
			bundle_code = ?
	);

    my $sth_bundle_rules = loadNocQuerySth( $sql_bundle_rules, $bundle_code );

    while ( my $record_bundle_rules = $sth_bundle_rules->fetchrow_hashref ) {
        my $rule_name = $record_bundle_rules->{rule_name};
        my $rule_data = $record_bundle_rules->{rule_data};

        $bundle_data{rules}{$rule_name} = $rule_data;
    }

    # Determine default server_role [if applicable]
    if ( defined $bundle_data{rules}{SERVER_ROLE} ) {
        my $server_role = uc $bundle_data{rules}{SERVER_ROLE};
        if ( ( $server_role eq 'DEFAULT' ) && ( defined $partner_id ) ) {
            my $default_srole = undef;

            my $sql_partner_default_srole = qq(
				SELECT
					pt2sr.server_role
				FROM
					partner AS p,
					partner_type_to_server_role AS pt2sr
				WHERE
					p.partner_type = pt2sr.partner_type AND
					p.partner_id = ? AND
					pt2sr.is_default = '1'
			);

            my $sth_partner_default_srole = loadNocQuerySth( $sql_partner_default_srole, $partner_id );

            if ( my $record_partner_default_srole = $sth_partner_default_srole->fetchrow_hashref ) {
                $default_srole = uc $record_partner_default_srole->{server_role};
            }

            $server_role = ( defined $default_srole ) ? $default_srole : undef;
        }

        $bundle_data{rules}{SERVER_ROLE} = $server_role;
    }

    # Set various rules -> properties [where applicable]
    #	 - btype
    if ( defined $bundle_data{rules}{BUNDLE_TYPE} ) {
        my $bundle_type = uc $bundle_data{rules}{BUNDLE_TYPE};
        $bundle_data{properties}{btype} = $bundle_type;
    } else {
        $bundle_data{error} = 1;
        $bundle_data{error_msg}{ $bundle_data{error_cnt} } = "Missing required bundle_type property.";
        $bundle_data{error_cnt}++;
    }

    #	 - bgrp
    if ( defined $bundle_data{rules}{BUNDLE_GROUP} ) {
        my $bundle_grp = uc $bundle_data{rules}{BUNDLE_GROUP};
        $bundle_data{properties}{bgrp} = $bundle_grp;
    } else {
        $bundle_data{error} = 1;
        $bundle_data{error_msg}{ $bundle_data{error_cnt} } = "Missing required bundle_group property.";
        $bundle_data{error_cnt}++;
    }

    #	 - srole
    if ( defined $bundle_data{rules}{SERVER_ROLE} ) {
        my $server_role = uc $bundle_data{rules}{SERVER_ROLE};
        $bundle_data{properties}{srole} = $server_role;
    }

    #	 - stype
    if ( defined $bundle_data{rules}{SERVER_TYPE} ) {
        my $server_type = uc $bundle_data{rules}{SERVER_TYPE};
        $bundle_data{properties}{stype} = $server_type;
    } else {
        $bundle_data{error} = 1;
        $bundle_data{error_msg}{ $bundle_data{error_cnt} } = "Missing required server_type property.";
        $bundle_data{error_cnt}++;
    }

    my $override_stype = NO;    # DEFAULT: NO
    if ( defined $bundle_data{rules}{OVERRIDE_SERVER_TYPE} ) {
        if ( ( uc $bundle_data{rules}{OVERRIDE_SERVER_TYPE} ) eq 'YES' ) {
            $override_stype = YES;
        }
    }
    $bundle_data{properties}{override_stype} = $override_stype;

    # FIXME: This should come from other schema for delivery/display properties
    #	- RELATIVE_DISPLAY_ORDER
    my $relative_display_order = undef;
    if ( defined $bundle_data{rules}{RELATIVE_DISPLAY_ORDER} ) {
        $relative_display_order = uc $bundle_data{rules}{RELATIVE_DISPLAY_ORDER};
    }

    $bundle_data{properties}{rel_display_order} = $relative_display_order;

    # FIXME: This should come from other schema for assignment engine operations
    #	- RELATIVE_APPLICATION_ORDER
    my $relative_application_order = undef;
    if ( defined $bundle_data{rules}{RELATIVE_APPLICATION_ORDER} ) {
        $relative_application_order = uc $bundle_data{rules}{RELATIVE_APPLICATION_ORDER};
    }

    $bundle_data{properties}{rel_application_order} = $relative_application_order;

    #   - swa_enrollment
    my $swa_enrollment = undef;
    if ( defined $bundle_data{rules}{SWA_ENROLLMENT} ) {
        my $swa_enrollment_check = uc $bundle_data{rules}{SWA_ENROLLMENT};
        $swa_enrollment = ( $swa_enrollment_check eq 'YES' ) ? YES : NO;
    }

    $bundle_data{properties}{swa_enrollment} = $swa_enrollment;

    # 	- is_capex
    my $is_capex = NO;
    if ( defined $bundle_data{rules}{IS_CAPEX} ) {
        my $is_capex_check = uc $bundle_data{rules}{IS_CAPEX};
        $is_capex = ( $is_capex_check eq 'YES' ) ? YES : NO;
    } else {
        if ( defined $bundle_data{rules}{BUNDLE_GROUP} ) {
            my $bundle_group = uc $bundle_data{rules}{BUNDLE_GROUP};
            $is_capex = ( $bundle_group eq 'CAPEX' ) ? YES : NO;
        }
    }

    $bundle_data{properties}{is_capex} = $is_capex;

    #	- is_subscription_based
    #	- requires_base_account_id
    my $is_subscription          = undef;
    my $requires_base_account_id = undef;
    if (   ( $bundle_data{properties}{btype} eq 'BASE' ) || ( $bundle_data{properties}{btype} eq 'EXTENSION' ) )    {

        $requires_base_account_id = NO;

        if ( defined $bundle_data{rules}{EXPIRES} ) {
            if ( $bundle_data{rules}{EXPIRES} eq 'infinite' ) {
                $is_subscription = NO;
            } else {
                $is_subscription = YES;
            }
        } else {
            # Return fatal error - BASE/EXTENSION must have an EXPIRES rule
            $bundle_data{error} = 1;
            $bundle_data{error_msg}{ $bundle_data{error_cnt} } = "Missing required 'EXPIRES' rule for BASE/EXTENSION";
            $bundle_data{error_cnt}++;
            $is_subscription = undef;
        }
    } else {    # Type=UPLIFT/UPGRADE

        if ( defined $bundle_data{rules}{EXPIRES} ) {
            if ( $bundle_data{rules}{EXPIRES} eq 'infinite' ) {
                $is_subscription          = NO;
                $requires_base_account_id = NO;
            } else {
# Return fatal error - UPLIFT/UPGRADE either are "infinite" or set to the same as the $base_account_id
                $bundle_data{error} = 1;
                $bundle_data{error_msg}{ $bundle_data{error_cnt} } = "Invalid rule, 'EXPIRES' != 'infinite', for UPLIFT/UPGRADE";
                $bundle_data{error_cnt}++;
                $is_subscription = YES; # Legacy behaviour expected: EXPIRES=<$duration> {calculated via $base_account_id}
                $requires_base_account_id = YES;
            }
        } else {
            if ($is_capex) {
                $is_subscription = NO; # Can't be both capex + subscription in UPLIFT/UPGRADE world
                $requires_base_account_id = NO;
            } else {
                # Will force to use $base_account_id
                $is_subscription          = YES;
                $requires_base_account_id = YES;
            }
        }
    }

    $bundle_data{properties}{is_subscription} = $is_subscription;
    $bundle_data{properties}{requires_base_account_id} = $requires_base_account_id;

    # 	- expires (simplified)
    my $expires = undef;
    if (( $bundle_data{properties}{btype} eq 'BASE' ) ||    # BASE/EXTENSION behaviour
        ( $bundle_data{properties}{btype} eq 'EXTENSION' )){

        if ($is_subscription) {
            $expires = $bundle_data{rules}{EXPIRES};
        } elsif ($is_capex) {
            $expires = 'infinite';
        } else {
            $bundle_data{error} = 1;
            $bundle_data{error_msg}{ $bundle_data{error_cnt} } = "Invalid 'expires' property, for BASE/EXTENSION";
            $bundle_data{error_cnt}++;
        }

    } else {    # UPGRADE/UPLIFT behaviour

        if ($is_capex) {
            $expires = 'infinite';
        }
    }
    $bundle_data{properties}{expires} = $expires;

    #	- is_revocable
    my $is_revocable = YES;
    if ( defined $bundle_data{rules}{REVOCABLE} ) {
        my $revocable = uc $bundle_data{rules}{REVOCABLE};
        $is_revocable = ( $revocable eq 'NO' ) ? NO : YES;
    }
    if (( $bundle_data{properties}{btype} eq 'BASE' ) ||    # BASE/EXTENSION behaviour
         ($bundle_data{properties}{btype} eq 'EXTENSION')
		) 
	{
        $is_revocable = NO;
    }

    $bundle_data{properties}{is_revocable} = $is_revocable;

    #	- allow_multi_base
    my $allow_multi_base = undef;
	if ( (defined $bundle_data{properties}{btype}) &&
		 ($bundle_data{properties}{btype} eq 'BASE') ) {

        if ( defined $bundle_data{rules}{ALLOW_MULTI_BASE} ) {

            my $multi_base = uc $bundle_data{rules}{ALLOW_MULTI_BASE};
            $allow_multi_base = ( $multi_base eq 'YES' ) ? YES : NO;

        } else {
            $allow_multi_base = NO;
        }
    }

    $bundle_data{properties}{allow_multi_base} = $allow_multi_base;

    # 	- SAP order processing
    my $process_sap_order = YES;
    if (   ( defined $bundle_data{rules}{AMC_PROCESS} ) && ( $bundle_data{rules}{AMC_PROCESS} eq 'DISABLED' ) ) {
        $process_sap_order = NO;
    }

    $bundle_data{properties}{process_sap_order} = $process_sap_order;

# Rework the REQUIRES_ACTIVE_SERVICE rule to include the description [for display purposes]
    if ( defined $bundle_data{rules}{REQUIRES_ACTIVE_SERVICE} ) {
        my $service_ids = $bundle_data{rules}{REQUIRES_ACTIVE_SERVICE};

        my @service_ids = split ',', $service_ids;

        my $new_rule_data = undef;
        foreach my $service_id (@service_ids) {
            my $service_desc = ( defined $system_services{$service_id} ) ? $system_services{$service_id}{desc} : 'Unknown';

            $new_rule_data .= "id|$service_id|desc|$service_desc,";
        }
        $new_rule_data =~ s/,$//;

        $bundle_data{rules}{REQUIRES_ACTIVE_SERVICE} = $new_rule_data;
    }

    # UPLIFT parts should have a requirement on an active BASE service
	if ( ($bundle_data{properties}{btype} eq 'UPLIFT') && (!defined $bundle_data{rules}{REQUIRES_ACTIVE_SERVICE}) ) {
        $bundle_data{error} = 1;
		$bundle_data{error_msg}{$bundle_data{error_cnt}} = "Missing required 'REQUIRES_ACTIVE_SERVICE' rule for UPLIFT";
        $bundle_data{error_cnt}++;
    }

# Capture  REQUIRES_ACTIVE_TAG rule into useable format (with description for display purposes)
    my %required_tags = ();
    if ( defined $bundle_data{rules}{REQUIRES_ACTIVE_TAG} ) {

        my $tag_list = $bundle_data{rules}{REQUIRES_ACTIVE_TAG};
        my @tags = split ',', $tag_list;

        foreach my $tag (@tags) {
            my $tag_desc = ( defined $system_tags{$tag} ) ? $system_tags{$tag}{desc} : 'Unknown';

            $required_tags{$tag}{desc} = $tag_desc;
        }
    }
    $bundle_data{required_tags} = \%required_tags;

    # [bundle_to_sub_bundle]
    #	- PROPERTY: is_high_level_bundle
    #	- list of sub-bundles + quantities
    my $is_hgh_lvl_bundle   = NO;
    my %hgh_lvl_sub_bundles = ();

    my $sql_sub_bundles = qq(
		SELECT
			bundles.bundle_code,
			bundles.active,
			bundle_to_sub_bundle.quantity
		FROM
			bundle_to_sub_bundle
				LEFT JOIN bundles
					ON bundle_to_sub_bundle.component_bundle_code = bundles.bundle_code
		WHERE
			bundle_to_sub_bundle.hgh_lvl_bundle_code = ?
	);

    my $sth_sub_bundles = loadNocQuerySth( $sql_sub_bundles, $bundle_code );

    while ( my $record_sub_bundles = $sth_sub_bundles->fetchrow_hashref ) {
        $is_hgh_lvl_bundle = YES;

        my $sub_bundle           = $record_sub_bundles->{bundle_code};
        my $sub_bundle_is_active = $record_sub_bundles->{active};
        my $qty                  = $record_sub_bundles->{quantity};

# TODO: return fatal error if supplying invalid sub-bundle or inactive-sub-bundle
        $hgh_lvl_sub_bundles{$sub_bundle}{qty} = $qty;
    }

    $bundle_data{properties}{is_high_level_bundle} = $is_hgh_lvl_bundle;
    $bundle_data{hgh_lvl_sub_bundles} = \%hgh_lvl_sub_bundles;

    # Bundle Delivery/Visibility [bundle_data]
    my @bundle_classes   = ();
    my $sql_bundle_class = qq(	
		SELECT
			bundle_class
		FROM
			bundle_data
		WHERE
			bundle_code = ?
	);

    my $sth_bundle_class = loadNocQuerySth( $sql_bundle_class, $bundle_code );

    while ( my $record_bundle_class = $sth_bundle_class->fetchrow_hashref ) {
        my $bundle_class = $record_bundle_class->{bundle_class};
        push @bundle_classes, $bundle_class;
    }

    $bundle_data{bundle_classes} = \@bundle_classes;

    # [bundle_dependencies]
    #	- parent
    #	- child
    #	- denies
    my @parent_bundles      = ();
    my @child_bundles       = ();
    my @deny_parent_bundles = ();
    my @deny_child_bundles  = ();

    my $sql_bundle_deps = qq(
		SELECT
			*
		FROM
			bundle_dependencies
		WHERE
			parent_bundle = ? OR
			child_bundle = ?
		ORDER BY
			rule,
			parent_bundle,
			child_bundle
	);

    my $sth_bundle_deps = loadNocQuerySth( $sql_bundle_deps, $bundle_code, $bundle_code );

    while ( my $record_bundle_deps = $sth_bundle_deps->fetchrow_hashref ) {

        my $parent_bundle = $record_bundle_deps->{parent_bundle};
        my $child_bundle  = $record_bundle_deps->{child_bundle};
        my $rule          = $record_bundle_deps->{rule};

     # FIXME: This should in fact use MAX_USES properties instead of bundle_deps
     # DENY $self
        if ((( $parent_bundle eq $child_bundle ) && ( $parent_bundle eq $bundle_code ))&& ( $rule eq 'DENY' ) ) {
            $bundle_data{rules}{MAX_USES} = 1;
        } else {

            if ( $rule eq 'ALLOW' ) {

                if ( $parent_bundle eq $bundle_code ) {

                    # Child Bundle
                    push @child_bundles, $child_bundle;

                } else {

                    # Parent Bundle
                    push @parent_bundles, $parent_bundle;

                }

            } elsif ( $rule eq 'DENY' ) {

                if ( $parent_bundle eq $bundle_code ) {

                    # Conflicting Child Bundle
                    push @deny_child_bundles, $child_bundle;

                } else {

                    # Conflicting Parent Bundle
                    push @deny_parent_bundles, $parent_bundle;

                }

            } else {
                # ERROR: This should never happen
            }

        }
    }

    $bundle_data{parent_bundles}      = \@parent_bundles;
    $bundle_data{child_bundles}       = \@child_bundles;
    $bundle_data{deny_parent_bundles} = \@deny_parent_bundles;
    $bundle_data{deny_child_bundles}  = \@deny_child_bundles;

    # [bundle_equivalents] - BASE only
    my @equivalent_bundles = ();

	if ( ($bundle_data{properties}{btype} eq 'BASE') || 
		 ($bundle_data{properties}{btype} eq 'EXTENSION') ) {

        my $sql_bundle_equivalents = qq(
			SELECT
				be.category,
				bundle_equivalents.bundle_code,
				be.comments
			FROM
				bundle_equivalents,
				bundle_equivalents AS be
			WHERE
				bundle_equivalents.category = be.category AND
				be.bundle_code = ? AND
				bundle_equivalents.bundle_code != ?
		);

        my $sth_bundle_equivalents = loadNocQuerySth( $sql_bundle_equivalents, $bundle_code,$bundle_code );

        while ( my $record_bundle_equivalents = $sth_bundle_equivalents->fetchrow_hashref )  {
            my $equivalent_bundle = $record_bundle_equivalents->{bundle_code};

            my $equiv_category = $record_bundle_equivalents->{category};
            my $equiv_desc     = $record_bundle_equivalents->{comments};
            $bundle_data{equivalent}{category} = $equiv_category;
            $bundle_data{equivalent}{desc}     = $equiv_desc;

            push @equivalent_bundles, $equivalent_bundle;
        }

        # include $self
        push @equivalent_bundles, $bundle_code;
    }

    $bundle_data{equivalent_bundles} = \@equivalent_bundles;
    # [partner_rules]
    my $is_partner_level_restricted = NO;
    my %partner_level_restrictions  = ();

    my $restriction_group           = undef;
    my $sql_group_restriction_query = qq(
		SELECT
			bundle_restriction_group,
			bundle_code
		FROM
			bundle_restriction
		WHERE
			bundle_code = ?
	);

    my $sth_bundle_res = loadNocQuerySth( $sql_group_restriction_query, $bundle_code );
    while ( my $row = $sth_bundle_res->fetchrow_hashref ) {
        $restriction_group = $row->{bundle_restriction_group};
    }

    if ( defined $restriction_group ) {

        my @restricted_bundles = ();

        my $sql_bundle_restriction_query = qq(
			SELECT
				bundle_code
			FROM
				bundle_restriction
			WHERE
				bundle_restriction_group = ?
		);

        my $sth_bundle_grp = loadNocQuerySth( $sql_bundle_restriction_query, $restriction_group );
        while ( my $row = $sth_bundle_grp->fetchrow_hashref ) {
            my $equivalent_bundle = $row->{bundle_code};
            push @restricted_bundles, $equivalent_bundle;
        }

        my $sql_partner_query = qq(
			SELECT
				partner_id,
				rule_data
			FROM
				partner_rules
			WHERE
				rule_name = ? AND
				rule_data like '%$restriction_group%'
			ORDER BY
				partner_id
		);

        my $sth_partner = loadNocQuerySth( $sql_partner_query,'NUM_ACTIVE_PRODUCT_APPLICATIONS_FOR_RESELLER' );
        while ( my $row = $sth_partner->fetchrow_hashref ) {
            $is_partner_level_restricted = YES;
            my $partner_id = $row->{partner_id};
            my $rule_data  = $row->{rule_data};

			my %rules_db = (
				'key'   => "rule|$rule_data",
			);

			my $max_applications = (defined db_get_prop (\%rules_db, 'key', 'max_applications'))?
										db_get_prop (\%rules_db, 'key', 'max_applications') : 1;

			$partner_level_restrictions{$restriction_group}{equivalent_bundles} = \@restricted_bundles;
			$partner_level_restrictions{$restriction_group}{partner_rules}{$partner_id} = $max_applications;
        }
    }

    $bundle_data{properties}{is_partner_level_restricted} = $is_partner_level_restricted;
    $bundle_data{partner_level_restrictions} = \%partner_level_restrictions;

# components
# FIXME: This should be more generic in that it should be driven by the end-component
#	     services, tags, and tallies rather than through the internal infrastructure
#		 of the AMC product model (aka [products]).
    my %product_components = ();

    my $sql_components = qq(
		SELECT
			products.product_code,
			products.product_desc
		FROM
			bundles,
			bundles_products
				LEFT JOIN products
					ON bundles_products.product_code = products.product_code
		WHERE
			bundles.bundle_code = bundles_products.bundle_code AND
			bundles.bundle_code = ?
	);

    my $sth_components = loadNocQuerySth( $sql_components, $bundle_code );

    while ( my $record_components = $sth_components->fetchrow_hashref ) {
        if ( $record_components->{product_code} ) {

            my $product_code = $record_components->{product_code};
            my $product_desc = $record_components->{product_desc};
            $product_components{$product_code}{desc} = $product_desc;

        } else {

            $bundle_data{error} = 1;
            $bundle_data{error_msg}{ $bundle_data{error_cnt} } = "Returned NULL value : undefined product code/description in [products]";
            $bundle_data{error_cnt}++;
        }
    }

    $bundle_data{components} = \%product_components;

    # services
    #	- normal services
    #	- license-based services
    my %active_services = ();

    my $sql_services = qq(
		SELECT
			services.service_id,
			services.service_name,
			pr_expires.rule_data AS expires
		FROM
			bundles_products,
			products_services
				LEFT JOIN product_rules AS pr_expires ON
					products_services.product_code = pr_expires.product_code AND
					pr_expires.rule_name = 'EXPIRES',
			services
		WHERE
			bundles_products.product_code = products_services.product_code AND
			products_services.service_id = services.service_id AND
			bundles_products.bundle_code = ?
	);

    my $sth_services = loadNocQuerySth( $sql_services, $bundle_code );

    while ( my $record_services = $sth_services->fetchrow_hashref ) {
        my $service_id   = $record_services->{service_id};
        my $service_name = $record_services->{service_name};
        my $expires      = $record_services->{expires};

		my $service_desc = (defined $system_services{$service_id})? $system_services{$service_id}{desc} : 'Unknown';
		my $is_licensed = (defined $license_based_services{$service_id})? YES : NO;

        $active_services{$service_id}{name}        = $service_name;
        $active_services{$service_id}{desc}        = $service_desc;
        $active_services{$service_id}{is_licensed} = $is_licensed;
        $active_services{$service_id}{expires}     = $expires;
    }
    $bundle_data{services} = \%active_services;

    # tags
    #	- service-based
    #	- bundle-based
    #	- type-based
    #	- role-based
    # -----------------
    my %tags = ();

    # Service Based (FIXME: Move service tags -> bundle-level (sync=12))
    # ------------------------------------------------------------------
    my $service_list = join(', ', keys %active_services) || undef;
    if ( defined $service_list ) {
        my $sql_service_tags = qq/
			SELECT
				service_id,
				tag
			FROM
				services_to_tags
			WHERE
				service_id IN ($service_list)
		/;

        my $sth_service_tags = loadNocQuerySth($sql_service_tags);

		while (my $record_service_tags = $sth_service_tags->fetchrow_hashref) {

            my $service_id     = $record_service_tags->{service_id};
            my $tag            = $record_service_tags->{tag};
            my $is_blade_based = ( defined $blade_based_tags{$tag} ) ? YES : NO;

            $tags{$tag}{is_blade_based} = $is_blade_based;
            $tags{$tag}{service_id}     = $service_id;
            $tags{$tag}{type}           = 'service';
            $tags{$tag}{expires} = $bundle_data{services}{$service_id}{expires};
        }
    }

    # Bundle Based
    # ------------
    my $sql_bundle_tags = qq(
		SELECT
			*	
		FROM
			bundles_to_tags
		WHERE
			bundle_code = ?
	);

    my $sth_bundle_tags = loadNocQuerySth( $sql_bundle_tags, $bundle_code );

    while ( my $record_bundle_tags = $sth_bundle_tags->fetchrow_hashref ) {
        my $tag = $record_bundle_tags->{tag};
        my $is_blade_based = ( defined $blade_based_tags{$tag} ) ? YES : NO;

        $tags{$tag}{is_blade_based} = $is_blade_based;
        $tags{$tag}{type}           = 'bundle';
        $tags{$tag}{expires} = $bundle_data{properties}{expires};    # Comes from BASE expiration
    }

    # Type Based
    # ----------
    if ( defined $bundle_data{rules}{SERVER_TYPE} ) {
        my $server_type = uc $bundle_data{rules}{SERVER_TYPE};
        my $stype_tag   = "SERVER_TYPE-$server_type";

		my $is_blade_based = (defined $blade_based_tags{$stype_tag})? YES : NO;

        $tags{$stype_tag}{is_blade_based} = $is_blade_based;
        $tags{$stype_tag}{type}           = 'system';
        $tags{$stype_tag}{expires} =       $bundle_data{properties}{expires};    # Comes from BASE expiration
    }

    # Role Based
    # ----------
    if ( defined $bundle_data{rules}{SERVER_ROLE} ) {
        my $server_role = uc $bundle_data{rules}{SERVER_ROLE};
        my $srole_tag   = "SERVER_ROLE-$server_role";

		my $is_blade_based = (defined $blade_based_tags{$srole_tag})? YES : NO;

        $tags{$srole_tag}{is_blade_based} = $is_blade_based;
        $tags{$srole_tag}{type}           = 'system';
        $tags{$srole_tag}{expires} =      $bundle_data{properties}{expires};    # Comes from BASE expiration
    }

    $bundle_data{tags} = \%tags;

    # REMOVE_TAGS -> @remove_tags
    # ---------------------------
    my @remove_tags = ();
    if ( defined $bundle_data{rules}{REMOVE_TAGS} ) {
        my $tag_list = $bundle_data{rules}{REMOVE_TAGS};
        push @remove_tags, split ',', $tag_list;
    }

    $bundle_data{remove_tags} = \@remove_tags;

    # REMOVE_SERVICES -> @remove_services
    # -----------------------------------
    my @remove_services = ();
    if ( defined $bundle_data{rules}{REMOVE_SERVICES} ) {
        my $service_list = $bundle_data{rules}{REMOVE_SERVICES};
        push @remove_services, split ',', $service_list;
    }

    $bundle_data{remove_services} = \@remove_services;

    # tallies
    #	- tally level
    #	- tally duration
    #		* normal
    #		* override
    #	- MAX value [if applicable]

    # There are services that are updated but not delivered
    #	ie: SOFTPHONE - Delivered softphones to the Ya service but
    #					does not deliver Ya
    # 			- We will check if key effecting here
    my %updated_services;
    my %tallies = ();
    my $sql_bundle_tallies = qq(
		SELECT
			tally_desc_lookup.*,
			product_rules.rule_data AS tally_value,
			tally_display_rules.rule_name AS display_rule,
			tally_display_rules.rule_value AS display_rule_value,
			tally_display_rules.display_value AS display_value
		FROM
			bundles_products,
			product_rules,
			tally_rules,
			tally_desc_lookup
				LEFT JOIN
					tally_display_rules ON
					tally_desc_lookup.tally_name = tally_display_rules.tally_name
		WHERE
			bundles_products.product_code = product_rules.product_code AND
			product_rules.rule_name = tally_rules.product_rule AND
			tally_rules.rule_data = tally_desc_lookup.tally_name AND
			bundles_products.bundle_code = ?
	);

    my $sth_bundle_tallies = loadNocQuerySth( $sql_bundle_tallies, $bundle_code );

    while ( my $record_bundle_tallies = $sth_bundle_tallies->fetchrow_hashref )  {
        my $tally_name = $record_bundle_tallies->{tally_name};
        my $service_id = $record_bundle_tallies->{service_id};
        my $tally_desc = $record_bundle_tallies->{tally_desc};
        my $tally_value = ( $record_bundle_tallies->{tally_value} eq 'infinite' ) ? INFINITE_TALLY : $record_bundle_tallies->{tally_value};

        $tallies{$tally_name}{service} = $service_id;
        $tallies{$tally_name}{desc}    = $tally_desc;
        $tallies{$tally_name}{value}   = $tally_value;

        # Display value
        #	- default to Tally value
        my $display_value = $tallies{$tally_name}{value};
        if ( defined $record_bundle_tallies->{display_rule} ) {
            my $display_rule     = $record_bundle_tallies->{display_rule};
            my $display_rule_val = $record_bundle_tallies->{display_rule_value};
            my $display_value_tmp = $record_bundle_tallies->{display_value};

            my %display_status = _get_tally_display_value( $tally_name, $display_rule, $display_rule_val, $display_value_tmp, $tally_value );

            if ( $display_status{error} ) {
                $bundle_data{error} = 1;
                $bundle_data{error_msg}{ $bundle_data{error_cnt} } = $display_status{error_msg};
                $bundle_data{error_cnt}++;
            } else {
                $display_value = $display_status{tally_display};
            }
        }

        $tallies{$tally_name}{display_value} = $display_value;

        # Seems to be updating a service (not delivered)
        unless ( defined $active_services{$service_id} ) {
            my $is_licensed = ( defined $license_based_services{$service_id} ) ? YES : NO;
            $updated_services{$service_id}{is_licensed} = $is_licensed;
        }
    }
   
    my $sql_bundles_products = qq(
		SELECT 
			count(*) as count_products
		FROM	
			bundles_products
		WHERE
			bundle_code = ?
	);

    my $sth_bundles_products = loadNocQuerySth( $sql_bundles_products, $bundle_code );
    my $bundles_products       = $sth_bundles_products->fetchrow_hashref;
    my $count_bundles_products = $bundles_products->{count_products};

    my $sql_bundles_tags = qq(
		SELECT
			 count(*) as count_tags
		FROM
			bundles_to_tags
		WHERE
			bundle_code= ?
     );

    my $sth_bundles_tags   = loadNocQuerySth( $sql_bundles_tags, $bundle_code );
    my $bundles_tags       = $sth_bundles_tags->fetchrow_hashref;
    my $count_bundles_tags = $bundles_tags->{count_tags};

    if ( $count_bundles_products == 0 && $count_bundles_tags > 0 ) {
        my $sql_tags_bundles = qq(
            SELECT 
                tag
            FROM
                bundles_to_tags
            WHERE
                bundle_code= ?
        );
        my $sth_tags_bundles = loadNocQuerySth( $sql_tags_bundles, $bundle_code );

        while( my $record_tags_bundles = $sth_tags_bundles->fetchrow_hashref){
            my $tags_bundles = $record_tags_bundles->{tag};

            if($system_tags{$tags_bundles}{is_license_affecting} == 1 && $system_tags{$tags_bundles}{active} == 1){
                $updated_services{$system_tags{$tags_bundles}{service_id}}{is_licensed} = YES;
            }
        }
    }

    $bundle_data{updated_services} = \%updated_services;
   
    # Determine expiry date for tally:
    #	 - check for special "expiry date" override (if applicable)
    #	 - otherwise default is same as BASE 'EXPIRES' rule (or 'undef')
    foreach my $tally ( keys %tallies ) {

        # - check for "expiry date" override
        my $sql_tally_expiry_override = qq(
			SELECT
				product_rules.rule_data
			FROM
				bundles_products,
				product_rules
			WHERE
				bundles_products.product_code = product_rules.product_code AND
				product_rules.rule_name = ? AND
				product_rules.rule_data LIKE '%$tally|%' AND
				bundles_products.bundle_code = ?
		);

        my $sth_tally_expiry_override = loadNocQuerySth( $sql_tally_expiry_override, 'SET_TALLY_DURATION',$bundle_code );

		if (my $record_tally_expiry_override = $sth_tally_expiry_override->fetchrow_hashref) {
            my $rule_data = $record_tally_expiry_override->{rule_data};

			my %rules_db = ( 
				'key'	=> "rule|$rule_data",
			);

            my $tally_check = db_get_prop( \%rules_db, 'key', 'tally' );
            my $duration    = db_get_prop( \%rules_db, 'key', 'duration' );

            if ( $tally eq $tally_check ) {
                $tallies{$tally}{expires} = $duration;
            }
        } else {
            if ( defined $bundle_data{rules}{EXPIRES} ) {
                $tallies{$tally}{expires} = $bundle_data{rules}{EXPIRES};
            } elsif ( $bundle_data{properties}{requires_base_account_id} ) {
                # Will come from [ab].termination_date of BASE product(s)
                $tallies{$tally}{expires} = undef;
            } else {
                $bundle_data{error} = 1;
				$bundle_data{error_msg}{$bundle_data{error_cnt}} = "Unable to determine expiration period for '$tally'";
                $bundle_data{error_cnt}++;
                $tallies{$tally}{expires} = undef;
            }
        }
    }

    # JPS check to make sure there are no service equivalent 
    # service_ids in the tallies. Might as well get them all as it
    # would be faster in the long run than doing SQL against each service_id key in tallies
    
    my $equivalent_id;
    
    my $equivalent_sql = qq(
        select service_id,
               equivalent_service_id 
          from services_equivalence   );
          
    my $sth_equivalent = loadNocQuerySth( $equivalent_sql);

    
    while ( my $equivalent = $sth_equivalent->fetchrow_hashref ){
        push(@{$equivalent_id->{$equivalent->{service_id}}},$equivalent->{equivalent_service_id });   
    }
  
      
         
    # Determine overall max value for tally	(if applicable)
  
 
    foreach my $tally ( keys %tallies ) {
        
        # JPS  Now we use the service_id (service key) from the tallies hash
        # see '_get_tally_to_systype_tags_restrictions' for what the new data hash looks like
        # to get the correct tally to add into the bundle_data
        
        my @tally_service_id = ($tallies{$tally}{service}); #will always be at least 1
        
        if (exists($equivalent_id->{$tally_service_id[0]})){
           push(@tally_service_id,@{$equivalent_id->{$tally_service_id[0]}}); #add in ewuilvalent ones if any
        }
        
        foreach my $tally_service_id (@tally_service_id){ 
            
           if ( defined $tally2systype_tags_restrictions{$tally_service_id}{$tally} ) {
               my ( $bundle_limit, $overall_limit ) = _determine_tally_max( $tally, $tally2systype_tags_restrictions{$tally_service_id},\%tags );
               $tallies{$tally}{'service_tally_limits'}{$tally_service_id}{bundle_limit}  = $bundle_limit;
               $tallies{$tally}{'service_tally_limits'}{$tally_service_id}{overall_limit} = $overall_limit;

               my %tags_to_limits = %{ $tally2systype_tags_restrictions{$tally_service_id}{$tally}{tags_to_limits} };
               $tallies{$tally}{'service_tally_limits'}{$tally_service_id}{tags_to_limits} = \%tags_to_limits;
            }           
        }
        
    }

    $bundle_data{tallies} = \%tallies;

 #	print STDERR Data::Dumper->Dump ([\%bundle_data], ['bundle_data']);

    return %bundle_data;
}

=item B<get_property_fields>

Retrieves an array of possible property values for a bundle
based on the product model version

=cut

# FIXME: Finish the product model version concept
sub get_property_fields {

    my $product_model_version = shift;

    if ( $product_model_version eq '1.0.0' ) {

        my %bundle_properties_v100 = (
            code => {
                display => 'Bundle Code',
                type    => 'value',
            },
            desc => {
                display => 'Description',
                type    => 'value',
            },
            active => {
                display => 'Active',
                type    => 'yes_no',
            },
            pay_period => {
                display => 'Pay Method',
                type    => 'value',
            },
            part_number => {
                display => 'SAP Code',
                type    => 'value',
            },
            part_number_override => {
                display => 'SAP Override',
                type    => 'value',
            },
            swa_part_number_override => {
                display => 'SWA Override',
                type    => 'value',
            },
            product_model_version => {
                display => 'Product Model Version',
                type    => 'value',
            },
            btype => {
                display => 'Bundle Type',
                type    => 'value',
            },
            bgrp => {
                display => 'Bundle Group',
                type    => 'value',
            },
            srole => {
                display => 'Server Role',
                type    => 'value',
            },
            stype => {
                display => 'Server Type',
                type    => 'value',
            },
            override_stype => {
                display => 'Override Server Type',
                type    => 'yes_no',
            },
            rel_display_order => {
                display => 'Relative Display Order',
                type    => 'value',
            },
            rel_application_order => {
                display => 'Relative Application Order',
                type    => 'value',
            },
            swa_enrollment => {
                display => 'SWA Enrollment',
                type    => 'yes_no',
            },
            is_capex => {
                display => 'Capex',
                type    => 'yes_no',
            },
            is_subscription => {
                display => 'Subscription',
                type    => 'yes_no',
            },
            expires => {
                display => 'Expires',
                type    => 'value',
            },
            requires_base_account_id => {
                display => 'Requires Base Account ID',
                type    => 'yes_no',
            },
            is_revocable => {
                display => 'Revocable',
                type    => 'yes_no',
            },
            allow_multi_base => {
                display => 'Allow Multiple Base Kits',
                type    => 'yes_no',
            },
            process_sap_order => {
                display => 'Process SAP-Based Orders',
                type    => 'yes_no',
            },
            is_high_level_bundle => {
                display => 'Has High-Level Bundle Requirements',
                type    => 'yes_no',
            },
            is_partner_level_restricted => {
                display => 'Restricts At VAR Account Level',
                type    => 'yes_no',
            },
        );

        return %bundle_properties_v100;

    } else {

        my %bundle_properties_default = ();

        return %bundle_properties_default;
    }
}

=item B<get_all_bundles>

Obtains a list of parts on the AMC with brief descriptive information
for those bundles:
	- code
	- desc
	- part_number
	- btype
	- stype
	- active

Allows filtering by 'active' (YES or NO) and 'server_type'

=cut

# FIXME: This should be replaced with Mitel::AMC::Search::Product
sub get_all_bundles {

    my $args = shift;

    my %AllBundles = ();

    my @vals_all_bundles = ();
    my $sql_all_bundles  = qq(
		SELECT
			b.bundle_code,
			b.bundle_desc,
			b.active,
			b2sl.sap_product_id,
			br_btype.rule_data AS btype,
			br_stype.rule_data AS stype
		FROM
			bundles AS b
				LEFT JOIN bundle_to_sap_lookup AS b2sl
					ON b.bundle_code = b2sl.bundle_code,
			bundle_rules AS br_btype,
			bundle_rules AS br_stype
		WHERE
			b.bundle_code = br_btype.bundle_code AND
			br_btype.rule_name = ? AND
			b.bundle_code = br_stype.bundle_code AND
			br_stype.rule_name = ?
	);
    push @vals_all_bundles, 'BUNDLE_TYPE', 'SERVER_TYPE';

    if ( defined $args->{active} ) {
        my $is_active = $args->{active};
        $sql_all_bundles .= qq(
			AND b.active = '$is_active'
		);
    }

    if ( defined $args->{server_type} ) {
        $sql_all_bundles .= qq(
			AND br_btype.rule_data = ? 
		);
        push @vals_all_bundles, $args->{server_type};
    }

    my $sth_all_bundles = loadNocQuerySth( $sql_all_bundles, @vals_all_bundles );

    while ( my $record_all_bundles = $sth_all_bundles->fetchrow_hashref ) {
        my $bcode       = $record_all_bundles->{bundle_code};
        my $bdesc       = $record_all_bundles->{bundle_desc};
        my $bactive     = $record_all_bundles->{active};
        my $part_number = $record_all_bundles->{sap_product_id};
        my $btype       = $record_all_bundles->{btype};
        my $stype       = $record_all_bundles->{stype};

        $AllBundles{$bcode}{desc}        = $bdesc;
        $AllBundles{$bcode}{active}      = $bactive;
        $AllBundles{$bcode}{part_number} = $part_number;
        $AllBundles{$bcode}{btype}       = $btype;
        $AllBundles{$bcode}{stype}       = $stype;
    }

    return %AllBundles;
}

=item B<get_pricebook_lookup>

Reads and stores [bundle_class_lookup] table.

=cut

sub get_pricebook_lookup {

    my %PriceBooks = ();

    my $sql_get_bundle_classes = qq(
		SELECT
			bundle_class,
			bundle_class_desc
		FROM
			bundle_class_lookup
	);

    my $sth_get_bundle_classes = loadNocQuerySth($sql_get_bundle_classes);

	while (my $record_get_bundle_classes = $sth_get_bundle_classes->fetchrow_hashref) {
        my $class = $record_get_bundle_classes->{bundle_class};
        my $desc  = $record_get_bundle_classes->{bundle_class_desc};

        $PriceBooks{$class} = $desc;
    }

    return %PriceBooks;
}

=item B<get_bundle_rule_fields>

Retrieves an array of possible bundle rules to support the
given product model version number.

Optional args:
	- is_active (active rules only, if set)
	- type (only those of specific type, if set)
	
Otherwise, all rules.
	
=cut

sub get_bundle_rule_fields {

    my $product_model_version = shift;
    my $rule_type             = shift || undef;
    my $rule_is_active        = shift || undef;

    my @bundle_rules = ();

    # - obtain the bundle rules from [bundle_rules_lookup] table
    my $sql_get_bundle_rules = qq(
		SELECT
			rule_name
		FROM
			bundle_rules_lookup
		WHERE
			product_model_version = ?
	);
    my @vals_get_bundle_rules = ($product_model_version);

    # - (if applicable) specify the rule_type (prop or rule)
    if ( defined $rule_type ) {
        if ( ( $rule_type eq 'prop' ) || ( $rule_type eq 'rule' ) ) {

            $sql_get_bundle_rules .= qq( AND rule_type = ?);
            push @vals_get_bundle_rules, $rule_type;
        }
    }

    # - (if applicable) specify active/inactive rules
    if ( defined $rule_is_active ) {
        if ( ( $rule_is_active == 1 ) || ( $rule_is_active == 0 ) ) {

            $sql_get_bundle_ruels .= qq( AND active = '$rule_is_active');
        }
    }

    my $sth_get_bundle_rules = loadNocQuerySth( $sql_get_bundle_rules, @vals_get_bundle_rules );

	while (my $record_get_bundle_rules = $sth_get_bundle_rules->fetchrow_hashref) {
        my $rule_name = $record_get_bundle_rules->{rule_name};

        push @bundle_rules, $rule_name;
    }

    return @bundle_rules;
}

=item B<check_swa_enrollment>
 
- Takes the given app record + service_id (swa) and uses that to determine:

NOTE: Assumes that the passed service has already been flagged as requiring
      initial enrollment.

 Is this server "enrolled"?
 	- BASE kit includes SWA
	- or:
		Enrollment parts applied

=cut

sub check_swa_enrollment {

    my $server_id      = shift;
    my $swa_service_id = shift;

    my $requires_swa_enrollment = undef;
    my $enrollment_applied      = undef;

    # Get list of products on this application record
    my $sql_product_history = qq(
		SELECT
			ab.account_id,
			ab.bundle_code,
			br_btype.rule_data AS btype,
			srvc.end_date AS swa_expiry,
			UNIX_TIMESTAMP(srvc.end_date) AS swa_expiry_sec,
			br_swa_enrollment.rule_data AS swa_enrollment
		FROM
			bundles AS b
				LEFT JOIN bundle_rules AS br_swa_enrollment
					ON b.bundle_code = br_swa_enrollment.bundle_code AND
					br_swa_enrollment.rule_name = ?, 
			accounts_billing AS ab,
			accounts_services AS srvc,
			bundle_rules AS br_btype
		WHERE
			ab.bundle_code = b.bundle_code AND
			ab.account_id = srvc.account_id AND
			ab.bundle_code = br_btype.bundle_code AND
			br_btype.rule_name = ? AND
			srvc.server_id = ? AND
			srvc.service_id = ?
	);

	my $sth_product_history = loadNocQuerySth ($sql_product_history, 'SWA_ENROLLMENT', 'BUNDLE_TYPE', $server_id, $swa_service_id);

    my %arid_products = ();
    while ( my $rec_products = $sth_product_history->fetchrow_hashref ) {
        my $acct_id        = $rec_products->{'account_id'};
        my $bcode          = $rec_products->{'bundle_code'};
        my $btype          = $rec_products->{'btype'};
        my $swa_expiry     = $rec_products->{'swa_expiry'};
        my $swa_expiry_sec = $rec_products->{'swa_expiry_sec'};

        # Check is_active
        my $is_active = ( $swa_expiry_sec > time ) ? YES : NO;

        # Check is_valid_swa_part
		my $is_valid_swa_part = _check_valid_swa_part ($bcode, $swa_service_id);	

        # Check is_swa_enrollment_part
        my $is_swa_enrollment = NO;
        if ( defined $rec_products->{'swa_enrollment'} ) {
            if ( $rec_products->{'swa_enrollment'} eq 'YES' ) {
                $is_swa_enrollment = YES;
            }
        }

        $arid_products{$acct_id}{'bcode'}             = $bcode;
        $arid_products{$acct_id}{'btype'}             = $btype;
        $arid_products{$acct_id}{'expiry_dt'}         = $swa_expiry;
        $arid_products{$acct_id}{'expiry_dt_sec'}     = $swa_expiry_sec;
        $arid_products{$acct_id}{'is_active'}         = $is_active;
        $arid_products{$acct_id}{'is_valid_swa_part'} = $is_valid_swa_part;
        $arid_products{$acct_id}{'is_swa_enrollment'} = $is_swa_enrollment;
    }

# Check for BASE kits that deliver the SWA service [directly, not through migration]
    my ( $num_valid_base_kits, $num_invalid_base_kits ) = ( 0, 0 );
    foreach my $acct_id ( keys %arid_products ) {
        next unless ( $arid_products{$acct_id}{'btype'} eq 'BASE' );

        if ( $arid_products{$acct_id}{'is_valid_swa_part'} ) {
            $num_valid_base_kits++;
        } else {
            $num_invalid_base_kits++;
        }
    }

    my $num_base_kits = ( $num_valid_base_kits + $num_invalid_base_kits );

    if ( $num_base_kits == 0 ) {
        # FIXME: This should return error condition
        $requires_swa_enrollment = undef;
        $enrollment_applied      = undef;
    } else {

        # Valid BASE kit -> No SWA enrollment requirement
        if ( $num_valid_base_kits > 0 ) {
            $requires_swa_enrollment = NO;
            $enrollment_applied      = NO;
        } else {
            $requires_swa_enrollment = YES;
            $enrollment_applied      = undef;

            # Determine if enrollment has been applied
            my ( $num_swa_ext, $num_swa_enrollment ) = ( 0, 0 );
            foreach my $acct_id ( keys %arid_products ) {
				if ( ($arid_products{$acct_id}{'btype'} eq 'EXTENSION') && ($arid_products{$acct_id}{'is_valid_swa_part'}) ) {
                    $num_swa_ext++;

                    if ( $arid_products{$acct_id}{'is_swa_enrollment'} ) {
                        $num_swa_enrollment++;
                    }
                }
            }

            if ( $num_swa_enrollment > 0 ) {
                $enrollment_applied = YES;
            } else {
# Also count those with valid SWA instead instead of enrollment (add re-enlist instead)

                if ( $num_swa_ext > 0 ) {
                    $enrollment_applied = YES;
                } else {
                    $enrollment_applied = NO;
                }
            }
        }
    }

    return ( $requires_swa_enrollment, $enrollment_applied );
}

=item B<is_bundle_initswa>
 
- Takes the given bundle_code and returns wether or not it is a InitSWA bundle

INPUT:  Bundle code we're desiring to know if it's a InitSWA bundle
OUTPUT: True (1) if the bundle is InitSWA, False (0) otherwise

=cut

sub is_bundle_initswa {
    my $bundle_code = shift;

    my $bundle_is_initswa     = 0;
    my $sql_is_initswa_bundle = qq(
        SELECT
            rule_data
        FROM
            bundle_rules
        WHERE
            bundle_code = ? AND
            rule_name   = ?
    );
    my $sth_is_initswa_bundle = loadNocQuerySth( $sql_is_initswa_bundle, $bundle_code,'IS_SWA_APPLICABLE' );

    if(my $rec_is_initswa_bundle = $sth_is_initswa_bundle->fetchrow_hashref){
        $bundle_is_initswa = 1 if($$rec_is_initswa_bundle{'rule_data'} eq 'YES');
    }

    return $bundle_is_initswa;
}

sub _check_valid_swa_part {

    my $bundle_code    = shift;
    my $swa_service_id = shift;

    my $sql_valid_swa_part = qq(
		SELECT
			count(*) AS is_valid
		FROM
			bundles AS b,
			bundles_products AS b2p,
			products_services AS p2s
		WHERE
			b.bundle_code = b2p.bundle_code AND
			b2p.product_code = p2s.product_code AND
			p2s.service_id = ? AND
			b.bundle_code = ?
	);

    my $sth_valid_swa_part = loadNocQuerySth( $sql_valid_swa_part, $swa_service_id, $bundle_code );

    my $is_valid_swa_part = NO;
    while ( my $rec_valid_swa_part = $sth_valid_swa_part->fetchrow_hashref ) {
        $is_valid_swa_part = $rec_valid_swa_part->{'is_valid'};
    }

    return $is_valid_swa_part;
}

=item B<get_swa_renewal_parts>

For a given app record/service combination, this determines the
appropriate set of SWA renewal part(s) that can be applied.
NOTE: Includes SWA re-enlistment part as no validation check is
done on current SWA expiration.

Returns empty hash if none found.

=cut

sub get_swa_renewal_parts {

    my $server_id      = shift;
    my $swa_service_id = shift;

    # Get all SWA renewal parts for this SWA service
    #	- delivers SWA renewal service(s)
    #	- active
    #	- bgrp = SWA
    #	- btype = EXTENSION
    my $sql_swa_renewal = qq(
		SELECT
			b.bundle_code,
			b2sl.sap_product_id,
			b.bundle_desc,
			br_expires.rule_data AS expire_days,
			br_tally_range.rule_data AS range_dependent_tally,
            br_swa_enroll.rule_data AS swa_enrollment 
		FROM
			bundles AS b
				LEFT JOIN bundle_rules AS br_tally_range
					ON b.bundle_code = br_tally_range.bundle_code AND
					   br_tally_range.rule_name = ?,
            bundles AS b2
				LEFT JOIN bundle_rules AS br_swa_enroll
					ON b2.bundle_code = br_swa_enroll.bundle_code AND
					   br_swa_enroll.rule_name = ?,
			bundle_to_sap_lookup AS b2sl,
            bundle_rules AS br_bgrp,
			bundle_rules AS br_btype,
			bundle_rules AS br_expires,
			bundles_products AS bp,
			products_services AS ps
		WHERE
            b.bundle_code = b2.bundle_code AND
			b.bundle_code = b2sl.bundle_code AND
            b.bundle_code = br_bgrp.bundle_code AND
			b.bundle_code = br_btype.bundle_code AND
			b.bundle_code = br_expires.bundle_code AND
			b.bundle_code = bp.bundle_code AND
			bp.product_code = ps.product_code AND
            br_bgrp.rule_name = ? AND
            br_bgrp.rule_data = ? AND
			br_btype.rule_name = ? AND
			br_btype.rule_data = ? AND
			br_expires.rule_name = ? AND
			ps.service_id = ? AND
			b.active = '1'
	);

    my $sth_swa_renewal = loadNocQuerySth($sql_swa_renewal, 'RANGE_DEPENDANT_TALLY','SWA_ENROLLMENT', 'BUNDLE_GROUP','SWA','BUNDLE_TYPE','EXTENSION','EXPIRES',$swa_service_id);

    my %swa_renewal_parts = ();
    while ( my $rec_swa_renewal = $sth_swa_renewal->fetchrow_hashref ) {
        my $bcode   = $rec_swa_renewal->{'bundle_code'};
        my $pn      = $rec_swa_renewal->{'sap_product_id'};
        my $bdesc   = $rec_swa_renewal->{'bundle_desc'};
        my $expires = $rec_swa_renewal->{'expire_days'};

        # FILTER: Re-enlist
        my $is_reenlist = NO;

        if ( $bcode =~ m/$REGEXPRenlistBundleCode/ ) {
            $is_reenlist = YES;
        }

        $swa_renewal_parts{$bcode}{'pn'}          = $pn;
        $swa_renewal_parts{$bcode}{'desc'}        = $bdesc;
        $swa_renewal_parts{$bcode}{'expires'}     = $expires;
        $swa_renewal_parts{$bcode}{'is_reenlist'} = $is_reenlist;
		$swa_renewal_parts{$bcode}{'range_dependent_tally'} = (defined $rec_swa_renewal->{'range_dependent_tally'})? $rec_swa_renewal->{'range_dependent_tally'} : undef;
		$swa_renewal_parts{$bcode}{'swa_enrollment'} = (defined $rec_swa_renewal->{'swa_enrollment'})? $rec_swa_renewal->{'swa_enrollment'} : undef;
    }

#	print STDERR Data::Dumper->Dump ([\%swa_renewal_parts], ['init_query']);
  
    # FILTER: Dependencies:
	my ($parent_allow, $parent_deny) = _get_parent_deps (\%swa_renewal_parts);
    my @app_record_bundles = _get_arid_bundles($server_id);

    #	- must have PARENT bundles
    foreach my $swa_bundle ( keys %swa_renewal_parts ) {
        my $is_allowed = NO;

        foreach my $arid_bundle (@app_record_bundles) {
			$is_allowed = YES if ( (defined $$parent_allow{$swa_bundle}{$arid_bundle}) &&
								   ($$parent_allow{$swa_bundle}{$arid_bundle}) );
        }

        unless ($is_allowed) {
            delete $swa_renewal_parts{$swa_bundle};
        }
    }

    #	print STDERR Data::Dumper->Dump ([\%swa_renewal_parts], ['parent_deps']);

    #	- remove any that are DENIED to parent bundles
    foreach my $swa_bundle ( keys %swa_renewal_parts ) {
        my $is_denied = NO;

        foreach my $arid_bundle (@app_record_bundles) {
			$is_denied = YES if ( (defined $$parent_deny{$swa_bundle}{$arid_bundle}) &&
								   ($$parent_deny{$swa_bundle}{$arid_bundle}) );
        }

        if ($is_denied) {
            delete $swa_renewal_parts{$swa_bundle};
        }

    }

    #	print STDERR Data::Dumper->Dump ([\%swa_renewal_parts], ['deny_deps']);

    #	- remove any that are SWA ENROLLMENT parts
    foreach my $swa_bundle ( keys %swa_renewal_parts ) {
        my $is_swa_enrollment = NO;
  	       $is_swa_enrollment = YES if ( (defined $swa_renewal_parts{$swa_bundle}{'swa_enrollment'}) &&
								   (uc $swa_renewal_parts{$swa_bundle}{'swa_enrollment'} eq 'YES') );

        if ($is_swa_enrollment) {
            delete $swa_renewal_parts{$swa_bundle};
        }

    }

    my ( $is_tally_range_dependent, $tally ) = ( NO, undef );
    foreach my $swa_bundle ( keys %swa_renewal_parts ) {
		if (defined $swa_renewal_parts{$swa_bundle}{'range_dependent_tally'}) {
            $is_tally_range_dependent = YES;
            $tally = $swa_renewal_parts{$swa_bundle}{'range_dependent_tally'};
        }
    }

    # FILTER: Range-based tally
    if ($is_tally_range_dependent) {

        _get_tally_range_rules( \%swa_renewal_parts );
#		print STDERR Data::Dumper->Dump ([\%swa_renewal_parts], ['mid_range_check']);

        my $tally_max = getTallyMax( $server_id, $tally );
        $tally_max = INFINITE_TALLY if ( $tally_max eq 'infinite' );

        foreach my $swa_bundle ( keys %swa_renewal_parts ) {
			my $range_low = (defined $swa_renewal_parts{$swa_bundle}{'range_low'})? $swa_renewal_parts{$swa_bundle}{'range_low'} : undef;
			my $range_hgh = (defined $swa_renewal_parts{$swa_bundle}{'range_hgh'})? $swa_renewal_parts{$swa_bundle}{'range_hgh'} : undef;

            if ( ( defined $range_low ) && ( defined $range_hgh ) ) {
				unless ( ($range_low <= $tally_max) && ($tally_max <= $range_hgh) ) {
                    delete $swa_renewal_parts{$swa_bundle};
                }
            } else {
                delete $swa_renewal_parts{$swa_bundle};
            }
        }
    }

 #	print STDERR Data::Dumper->Dump ([\%swa_renewal_parts], ['range_dependant']);

    return %swa_renewal_parts;
}

=item B<_get_service_details>

Put the [services] table into a usable data structure

=cut

sub _get_service_details {

    my %services = ();

    my $sql_services = qq(
		SELECT
			*
		FROM
			services
	);

    my $sth_services = loadNocQuerySth($sql_services);

    while ( my $record_services = $sth_services->fetchrow_hashref ) {
        my $service_id   = $record_services->{service_id};
        my $service_name = $record_services->{service_name};
        my $service_desc = $record_services->{service_desc};

        $services{$service_id}{name} = $service_name;
        $services{$service_id}{desc} = $service_desc;
    }

    return %services;
}

=item B<_get_tag_details>

Put the [tags] table into a usable data structure

=cut

sub _get_tag_details {

    my %tags = ();

    my $sql_tags = qq(
		SELECT
			*
		FROM
			tags	
	);

    my $sth_tags = loadNocQuerySth($sql_tags);

    while ( my $record_tags = $sth_tags->fetchrow_hashref ) {
        my $tag_name              = $record_tags->{tag_name};
        my $tag_desc              = $record_tags->{tag_description};
        my $type                  = $record_tags->{type};
        my $immutable             = $record_tags->{immutable} || undef;
        my $tag_service_id        = $record_tags->{service_id};
        my $tag_license_affecting = $record_tags->{is_license_affecting};
        my $tag_active            = $record_tags->{active};

        $tags{$tag_name}{desc}                 = $tag_desc;
        $tags{$tag_name}{type}                 = $type;
        $tags{$tag_name}{immutable}            = $immutable;
        $tags{$tag_name}{service_id}           = $tag_service_id;
        $tags{$tag_name}{is_license_affecting} = $tag_license_affecting;
        $tags{$tag_name}{active}               = $tag_active;
    }

    return %tags;
}

=item B<_get_tally_to_systype_tags_restrictions>

Creates a hash structure to show the service_id->tally -> systype level tag
restrictions by consolidating:


	[service_tally_rules]
	[tally_tag_rules]

will rerunt a hash like this
	
	{'49' => {'ME_CLIENT_LIC'       => {'service_id'     => '49',
                                       'overall_max'    => '999999',
                                       'tags_to_limits' => {'MAS_SYSTYPE_CORE_1_2' => '300',
                                                            'MAS_SYSTYPE_CORE_2_0' => '500',
                                                            'MAS_SYSTYPE_MOBILITY' => '300'}},
             'MOBILITY_PHONE_SETS' => {'service_id'     => '49',
                                       'overall_max'    => '505',
                                       'tags_to_limits' => {'MAS_SYSTYPE_CORE_1_0' => '150',
                                                            'MAS_SYSTYPE_CORE_1_1' => '150',
                                                            'ME_SYSTYPE_MAS'       => '150',
                                                            'MAS_SYSTYPE_CORE_1_2' => '300',
                                                            'MAS_SYSTYPE_CORE_2_0' => '500',
                                                            'MAS_SYSTYPE_MOBILITY' => '300'}},
              },
    'MOBILITY_PHONE_SETS' => {
                                    'expires' => 'infinite',
                                    'service' => '49',
                                    'desc' => 'MCD Network/Digital Link',
                                    'value' => '1',
                                    'display_value' => '1'
                                  },... }
                                                      
                                                   
=cut

# JPS Rewrite for Bug #18301
# the data structure will have to be based on service_id like this
#  tally_to_systype_tags_restrictions = {SERVICE_ID => {TALLY_NAME=>{overall_max =>'n...',
#                                                                    service_id  =>'n..',
#                                                                     tags_to_limits=>{TAG_NAME=>'n...'}}},
#                                         TALLY_NAME => {'expires' => 'bla bla',
#                                                        'service' => 'n...',
#                                                        'desc'    => 'some tag description',
#                                                        'value'   => 'n..',
#                                                        'display_value' => '1|0'}}

#  with the detailed service_id tallies for the tally key 
#  as well as the orginal tally key for its tombstone data which will be used for display etc and should
#  have nothing to do with with service_id 
#  this avoids a problem with the old structure where the TALLY_NAME from one
#  service_id would overwrite a TALLY_NAME for another service_id

sub _get_tally_to_systype_tags_restrictions {

    my %tally_to_systype_tags_restrictions = ();

    # [service_tally_rules] -> overall tally max
    my $sql_overall_tally_limits = qq(
		SELECT
			tally_name,
			service_id,
			rule_data AS max
		FROM
			service_tally_rules
		WHERE
			rule_name = ?
	);

    my $sth_overall_tally_limits = loadNocQuerySth( $sql_overall_tally_limits, 'SERVER_MAX_TALLY_LEVEL' );

    while ( my $record_overall_tally_limits = $sth_overall_tally_limits->fetchrow_hashref )
    {
        my $tally_name        = $record_overall_tally_limits->{tally_name};
        my $service_id        = $record_overall_tally_limits->{service_id};
        my $overall_tally_max = $record_overall_tally_limits->{max};
        my $tally_hash        = {
            service_id  => $service_id,
            overall_max => $overall_tally_max
        };

        $tally_to_systype_tags_restrictions{$service_id}{$tally_name} =  $tally_hash;
    }


    # [tally_tag_rules] -> tag-based restrictions
    my %tally_tag_limits_hash = ();

    my $sql_tally_tag_limits = qq(
		SELECT
			tally_name,
			tag_name,
			rule_data AS tag_limit
		FROM
			tally_tag_rules
		WHERE
			rule_name = ?	
	);

    my $sth_tally_tag_limits = loadNocQuerySth( $sql_tally_tag_limits, 'SERVER_MAX_TALLY_LEVEL' );

    while ( my $record_tally_tag_limits = $sth_tally_tag_limits->fetchrow_hashref )  {

        my $tally_name = $record_tally_tag_limits->{tally_name};
        my $tag        = $record_tally_tag_limits->{tag_name};
        my $limit      = $record_tally_tag_limits->{tag_limit};

        foreach my $service_id (keys(%tally_to_systype_tags_restrictions)){
           $limit = $tally_to_systype_tags_restrictions{$service_id}{$tally_name}{overall_max}
              if ( defined $tally_to_systype_tags_restrictions{$service_id}{$tally_name}{'overall_max'} && $limit eq 'maximum' );
        }
        $tally_tag_limits_hash{$tally_name}{$tag} = $limit;
    }

    #the above limits are for each TALLY_NAME and are not effected my service_id

    #loop over each service_id to get the limits for its TALLY_NAMEs

    foreach my $service_id ( keys(%tally_to_systype_tags_restrictions) ) {

        foreach my $tally_name ( keys %tally_tag_limits_hash ) {

            # - if not specified in [service_tally_rules], assume "No limit"
            unless (defined($tally_to_systype_tags_restrictions{$service_id}{$tally_name})){
                $tally_to_systype_tags_restrictions{$service_id}{$tally_name}{service_id} = undef;
                $tally_to_systype_tags_restrictions{$service_id}{$tally_name}{overall_max} = INFINITE_TALLY;
            }

            my %tags_to_limits = %{ $tally_tag_limits_hash{$tally_name} };

            $tally_to_systype_tags_restrictions{$service_id}{$tally_name}{tags_to_limits} = \%tags_to_limits;
        }
    }

 return %tally_to_systype_tags_restrictions;

}

=item B<_get_license_services>

Put the [service_license] table into a usable data structure

=cut

sub _get_license_services {

    my %license_services = ();

    my $sql_license_based_services = qq(
		SELECT
			DISTINCT service_id
		FROM
			service_license
	);

    my $sth_license_based_services = loadNocQuerySth($sql_license_based_services);

	while (my $record_license_based_services = $sth_license_based_services->fetchrow_hashref) {
        my $service_id = $record_license_based_services->{service_id};

        $license_services{$service_id} = 1;
    }

    return %license_services;
}

=item B<_get_blade_tags>

Put the [blades_tags] table into a usable data structure.

=cut

sub _get_blade_tags {

    my %blade_tags = ();

    my $sql_blade_based_tags = qq(
		SELECT
			DISTINCT blade_tags.tag
		FROM
			tags,
			blade_tags,
			blades
		WHERE
			blades.blade_id = blade_tags.blade_id AND
			blade_tags.tag = tags.tag_name AND
			blade_tags.operation = 'ALLOW'
	);

    my $sth_blade_based_tags = loadNocQuerySth($sql_blade_based_tags);

	while (my $record_blade_based_tags = $sth_blade_based_tags->fetchrow_hashref) {
        my $tag = $record_blade_based_tags->{tag};

        $blade_tags{$tag} = 1;
    }

    return %blade_tags;
}

=item B<_get_tally_display_value>

Figures out the complexity of [tally_display_rules] for
the given arguments:

	$tally_name
	$rule_name		(TALLY_MATCH, TALLY_RANGE)
	$rule_key
	$rule_val_hash
	$tally_value

=cut

sub _get_tally_display_value {

    my $tally_name    = shift;
    my $rule_name     = shift;
    my $rule_key      = shift;
    my $rule_val_hash = shift;
    my $tally_value   = shift;

    my %status = (
        tally_display => $tally_value, # default display to show the tally_value
        error         => 0,
        error_msg     => undef,
    );

    if ( $rule_name eq 'TALLY_MATCH' ) {
        if ( $tally_value == $rule_key ) {
            $status{tally_display} = $rule_val_hash;
        }
    } elsif ( $rule_name eq 'TALLY_RANGE' ) {

        my @ranges     = split /\|/, $rule_key;
        my @range_vals = split /\|/, $rule_val_hash;

        my $range_position = 0;
        for ( my $range_cnt = 0 ; $range_cnt <= $#ranges ; $range_cnt++ ) {

            if ( $tally_value >= $ranges[$range_cnt] ) {
                $range_position = $range_cnt;
            }
        }

        my $tally_display = $range_vals[$range_position];
        if ( $tally_display eq 'TALLY' ) {
            $tally_display = $tally_value;
        }

        $status{tally_display} = $tally_display;

    } else {
        $status{error}     = 1;
        $status{error_msg} = "Invalid tally display rule: $rule_name";
    }

    return %status;
}

=item B<_determine_tally_max>

Calculates the tally limit restrictions for:

	- this bundle
	- overall for the tally

based on [service_tally_rules] and [tally_tag_rules] data
structure.

=cut

sub _determine_tally_max {

    my $tally_name                        = shift;
    my $tally_systype_tag_restriction_ref = shift;
    my $bundle_tags_ref                   = shift;

    my $bundle_limit  = -1;
    my $overall_limit = INFINITE_TALLY;    # DEFAULT: MAX

    # Grab the AMC system level limit
	$overall_limit = $$tally_systype_tag_restriction_ref{$tally_name}{overall_max}
		if (defined $$tally_systype_tag_restriction_ref{$tally_name}{overall_max});

    # Determine the bundle-level limit (from tags)
    foreach my $tag ( keys %{$bundle_tags_ref} ) {
            
		if (defined $$tally_systype_tag_restriction_ref{$tally_name}{tags_to_limits}{$tag}) {
            my $tag_limit = $$tally_systype_tag_restriction_ref{$tally_name}{tags_to_limits}{$tag};
        
            if ( $tag_limit > $bundle_limit ) {
                $bundle_limit = $tag_limit;
            }
        }
    }

    # Indicate if this bundle does not provide a limit itself [force use MAX]
    $bundle_limit = undef if ( $bundle_limit == -1 );

    return ( $bundle_limit, $overall_limit );
}

=item B<_is_part_number_duplicated>


=cut

sub _is_part_number_duplicated {

    my $bundle_code     = shift;
    my $sap_part_number = shift;

    my $is_duplicated = NO;

    my $sql_check_duplicated_active_part = qq(
		SELECT
			count(*) AS num_other_active
		FROM
			bundles,
			bundle_to_sap_lookup
		WHERE
			bundles.bundle_code = bundle_to_sap_lookup.bundle_code AND
			bundle_to_sap_lookup.sap_product_id = ? AND
			bundles.bundle_code != ? AND
			bundles.active = '1'
	);

    my $sth_check_duplicated_active_part = loadNocQuerySth( $sql_check_duplicated_active_part,$sap_part_number, $bundle_cde );

	if (my $record_check_duplicated_active_part = $sth_check_duplicated_active_part->fetchrow_hashref) {
        my $num_other_active = $record_check_duplicated_active_part->{num_other_active};

        if ( $num_other_active > 0 ) {
            $is_duplicated = YES;
        }
    }

    return $is_duplicated;
}

=item B<validateBundleDependencies>
Validates the parent_bundle, child_bundle and rule prior to editing bundle_dependencies table
=cut
sub validateBundleDependencies {
    my $args           = shift;
    my %validateResult = (
        error     => 0,
        error_msg => undef,
    );
    my $parent_exist = '';
    my $child_exist  = '';
    my $user_id      = $args->{user_id};
    my $parent_code  = $args->{parent_bundle};
    my $child_code   = $args->{child_bundle};
    my $rule         = $args->{rule};
    my $reason       = $args->{reason};
    my $sql          = qq(
				SELECT 
						*
				FROM
						bundles
				WHERE
						bundle_code = ? OR
						bundle_code = ?
	

				);
    my $sth = loadNocQuerySth( $sql, $parent_code, $child_code );
    while ( my $row = $sth->fetchrow_hashref ) {
			if ($row->{bundle_code} eq $parent_code)
			{
            $parent_exist = 1;
        }
			if ($row->{bundle_code} eq $child_code)
			{
            $child_exist = 1;
        }
    }

    # Check valid user

    my $sql_check_user = qq(
        SELECT
            *
        FROM
            users
        WHERE
            user_id = ?
    );

    my $sth_check_user = loadNocQuerySth( $sql_check_user, $user_id );
    if ( $sth_check_user->rows eq '0' ) {

        $validateResult{error}     = 1;
        $validateResult{error_msg} = "Invalid user_id.";
    }

    unless ( $parent_exist eq '1' ) {
        $validateResult{error}     = 1;
        $validateResult{error_msg} = "Invalid parent bundle_code.";
    }
    unless ( $child_exist eq '1' ) {
        $validateResult{error}     = 1;
        $validateResult{error_msg} = "Invalid child bundle_code.";
    }
    unless ( $rule eq 'ALLOW' || $rule eq 'DENY' ) {
        $validateResult{error}     = 1;
        $validateResult{error_msg} = "Invalid rule.";
    }

    my $sql_valid_request = qq(
							SELECT
									*
							FROM 
									bundle_dependencies
							WHERE
									parent_bundle = ? AND
									child_bundle = ? 
							);
	my $sth_valid_request = loadNocQuerySth($sql_valid_request,$parent_code,$child_code);
	if ( my $row_valid_request = $sth_valid_request->fetchrow_hashref )
	{
        if ( $args->{add} ) {
            $validateResult{error} = 1;
            $validateResult{error_msg} = "Invalid insert option, row already exists";

        }
        if ( $row_valid_request->{rule} eq $rule && $args->{update} ) {
            $validateResult{error} = 1;
            $validateResult{error_msg} = "Invalid update option, row already exists";

        }
        if ( $args->{remove} && $row_valid_request->{rule} ne $rule ) {
            $validateResult{error} = 1;
            $validateResult{error_msg} = "Invalid remove option, row does not exist";
        }
    } else {
        if ( $args->{remove} ) {
            $validateResult{error} = 1;
            $validateResult{error_msg} = "Invalid remove option, row does not exist";
        }
        if ( $args->{update} ) {
            $validateResult{error} = 1;
            $validateResult{error_msg} = "Invalid update option, row does not exist";
        }

    }
    return %validateResult;
}

=item B<changeBundleDependencies>
Edits bundle_dependencies table, by adding, updating or removing entries 
=cut
sub changeBundleDependencies {
    my $args                 = shift;
    my $user_id              = $args->{user_id};
    my $parent_bundle        = $args->{parent_bundle};
    my $child_bundle         = $args->{child_bundle};
    my $rule                 = $args->{rule};
    my $reason               = $args->{reason};
    my %validateUpdateStatus = (
        error     => 0,
        error_msg => undef,
    );
    return %validateResult if ( $validateResult{error} );
    if ( $args->{add} ) {
        my $sql = qq(
				INSERT INTO bundle_dependencies VALUES (?,?,?)
				);
	unless (my $sth = updateNocQuerySth($sql,$parent_bundle,$child_bundle,$rule)){
            $validateUpdateStatus{error}     = 1;
            $validateUpdateStatus{error_msg} = "Could not perform add";
        }
        # insert into audit table
        my $context    = 'NOC_ADMIN';
        my $event_type = 'ADMIN_PRODUCT_BUNDLE_DEPENDENCY_ADD';
        my $event_data = "parent bundle|$parent_bundle|child bundle|$child_bundle|rule|$rule|reason|$reason";
        my $test_audit = new esmith::Broker::Audit;
        $test_audit->{context}    = $context;
        $test_audit->{user_id}    = $user_id;
        $test_audit->{event_type} = $event_type;
        $test_audit->{event_data} = $event_data;
        unless($test_audit->create($event_data))
        {
            print STDERR "Could not insert into the audit table in Products::changeBundleDependencies:add\n";
        }

    } elsif ( $args->{remove} ) {
        my $sql = qq(
				DELETE FROM bundle_dependencies WHERE parent_bundle = ? and child_bundle = ? and rule = ?
                );
    unless (my $sth = updateNocQuerySth($sql,$parent_bundle,$child_bundle,$rule)){
            $validateUpdateStatus{error}     = 1;
            $validateUpdateStatus{error_msg} = "Could not perform remove";
        }
        # insert into audit table
        my $context    = 'NOC_ADMIN';
        my $event_type = 'ADMIN_PRODUCT_BUNDLE_DEPENDENCY_REMOVE';
        my $event_data = "parent bundle|$parent_bundle|child bundle|$child_bundle|rule|$rule|reason|$reason";
        my $test_audit = new esmith::Broker::Audit;
        $test_audit->{context}    = $context;
        $test_audit->{user_id}    = $user_id;
        $test_audit->{event_type} = $event_type;
        $test_audit->{event_data} = $event_data;
        unless($test_audit->create($event_data))
        {
            print STDERR "Could not insert into the audit table in Products::changeBundleDependencies:remove\n";
        }

    } elsif ( $args->{update} ) {

        my $sql = qq(
				UPDATE bundle_dependencies SET rule = ? WHERE parent_bundle = ? and child_bundle = ? 
                );
    unless (my $sth = updateNocQuerySth($sql,$rule,$parent_bundle,$child_bundle)){

            $validateUpdateStatus{error}     = 1;
            $validateUpdateStatus{error_msg} = "Could not perform update";
        }
        # insert into audit table
        my $context    = 'NOC_ADMIN';
        my $event_type = 'ADMIN_PRODUCT_BUNDLE_DEPENDENCY_UPDATE';
        my $event_data = "parent bundle|$parent_bundle|child bundle|$child_bundle|new rule|$rule|reason|$reason";
        my $test_audit = new esmith::Broker::Audit;
        $test_audit->{context}    = $context;
        $test_audit->{user_id}    = $user_id;
        $test_audit->{event_type} = $event_type;
        $test_audit->{event_data} = $event_data;
        unless($test_audit->create($event_data))
        {
            print STDERR "Could not insert into the audit table in Products::changeBundleDependencies:update\n";
        }

    }
    return %validateUpdateStatus;
}

=item B<_get_parent_deps>

For list of bundles, gets all parent dependencies in two
separate hashes:

 %allow_deps
 %deny_deps

=cut

sub _get_parent_deps {

    my $bundles_ref = shift;

    my $bundle_list = "'_INVALID_'";
    foreach my $bundle_code ( keys %{$bundles_ref} ) {
        $bundle_list .= ",'$bundle_code'";
    }

    my $sql_bundle_deps = qq(
		SELECT
			*
		FROM
			bundle_dependencies
		WHERE
			child_bundle IN ($bundle_list)
	);

    my $sth_bundle_deps = loadNocQuerySth($sql_bundle_deps);

    my %allow_deps = ();
    my %deny_deps  = ();
    while ( my $rec_deps = $sth_bundle_deps->fetchrow_hashref ) {
        my $pbundle = $rec_deps->{'parent_bundle'};
        my $cbundle = $rec_deps->{'child_bundle'};
        my $rule    = $rec_deps->{'rule'};

        if ( $rule eq 'ALLOW' ) {
            $allow_deps{$cbundle}{$pbundle} = 1;
        } else {
            $deny_deps{$cbundle}{$pbundle} = 1;
        }
    }

    return ( \%allow_deps, \%deny_deps );
}

=item B<_get_arid_bundles>
=cut

sub _get_arid_bundles {
    my $server_id = shift;

    my @server_bundles = ();

    my $sql_ab = qq(
		SELECT
			DISTINCT bundle_code
		FROM
			accounts_billing
		WHERE
			server_id = ?
	);

    my $sth_ab = loadNocQuerySth( $sql_ab, $server_id );

    while ( my $rec_ab = $sth_ab->fetchrow_hashref ) {
        my $bcode = $rec_ab->{'bundle_code'};

        push @server_bundles, $bcode;
    }

    return @server_bundles;
}

1;

=item B<_get_tally_range_rules>
=cut

sub _get_tally_range_rules {

    my $bundles_ref = shift;

    my $bundle_list = "'_INVALID_'";
    foreach my $bundle_code ( keys %{$bundles_ref} ) {
        $bundle_list .= ",'$bundle_code'";
    }

    my $sql_tally_range_rules = qq(
		SELECT
			bundles.bundle_code,
			br_range_low.rule_data AS range_low,
			br_range_hgh.rule_data AS range_hgh
		FROM
			bundles,
			bundle_rules AS br_range_low
				LEFT JOIN bundle_rules AS br_range_hgh
					ON br_range_low.bundle_code = br_range_hgh.bundle_code AND
					   br_range_hgh.rule_name = ?
		WHERE
			bundles.bundle_code = br_range_low.bundle_code AND
			br_range_low.rule_name = ? AND
			bundles.bundle_code IN ($bundle_list)
	);

	my $sth_tally_range_rules = loadNocQuerySth ($sql_tally_range_rules, 'TALLY_RANGE_UPPER_BOUND', 'TALLY_RANGE_LOWER_BOUND');

    while ( my $rec_rules = $sth_tally_range_rules->fetchrow_hashref ) {
        my $bcode     = $rec_rules->{'bundle_code'};
        my $range_low = $rec_rules->{'range_low'};
        my $range_hgh = $rec_rules->{'range_hgh'};

        if ( ( defined $range_low ) && ( !defined $range_hgh ) ) {
            $range_hgh = INFINITE_TALLY;
        }

        $$bundles_ref{$bcode}{'range_low'} = $range_low;
        $$bundles_ref{$bcode}{'range_hgh'} = $range_hgh;
    }
}

=back

=head1 AUTHOR

Mitel

=cut
