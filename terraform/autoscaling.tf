# =========================================================
# Data
# =========================================================

data "aws_ami" "amazon_linux2023" {
    most_recent = true
    filter {
        name   = "name"
        values = [ "al2023-ami-2023.*-kernel-6.1-x86_64" ]
    }
    filter {
        name   = "virtualization-type"
        values = [ "hvm" ]
    }
    filter {
        name   = "architecture"
        values = [ "x86_64" ]
    }
    owners = [ "amazon" ]
}

data "aws_ip_ranges" "ec2_instance_connect" {
    regions  = [ local.region_name ]
    services = [ "ec2_instance_connect" ]
}

data "aws_security_group" "bastion_extra" {
    for_each = toset(var.extra_security_groups)

    id   = can(regex("^sg-([a-f0-9]{8}|[a-f0-9]{17})$", each.value)) ? each.value : null
    name = can(regex("^sg-([a-f0-9]{8}|[a-f0-9]{17})$", each.value)) ? null : each.value

    vpc_id = local.vpc_id
}


# =========================================================
# Data: Cloud Init
# =========================================================

data "cloudinit_config" "bastion_userdata" {
    depends_on = [
        aws_s3_object.assets_cloudinit,
        aws_s3_object.assets_extra_scripts,
        aws_s3_object.assets_extra_config,
    ]

    part {
        filename     = "init.sh"
        content_type = "text/cloud-boothook"
        content      = templatefile(
            "templates/bastion-cloud-init-configscript.sh",
            {
                region       = local.region_name
                contact      = var.contact
                asg_name     = local.asg_name
                prompt_name  = local.name
                login_banner = var.login_banner

                sharedfs_id                = aws_efs_file_system.sharedfs.id
                sharedfs_home_uofi_id      = aws_efs_access_point.sharedfs_home_uofi.id
                sharedfs_var_spool_at_id   = aws_efs_access_point.sharedfs_var_spool_at.id
                sharedfs_var_spool_cron_id = aws_efs_access_point.sharedfs_var_spool_cron.id
                extra_efs                  = local.extra_efs

                sharedfs_mount_targets = local.vpc_id == local.internal_vpc_id ? "" : join(
                    " ",
                    formatlist(
                        "[%s]='%s'",
                        aws_efs_mount_target.sharedfs[*].availability_zone_name,
                        aws_efs_mount_target.sharedfs[*].ip_address,
                    )
                )

                loggroup_prefix                  = local.loggroup_prefix
                metrics_namespace                = local.metrics_namespace
                metrics_collection_interval      = var.enhanced_monitoring ? 60 : 300
                journald_cloudwatch_logs_package = "s3://${aws_s3_object.assets_cloudinit["journald-cloudwatch-logs"].bucket}/${aws_s3_object.assets_cloudinit["journald-cloudwatch-logs"].key}"

                cis_shell_timeout = var.shell_idle_timeout

                sss_admingroups_parameter = "/${local.sss_parameter_prefix}admin-groups"
                sss_allowgroups_parameter = "/${local.sss_parameter_prefix}allow-groups"
                sss_binduser_parameter    = "/${local.sss_parameter_prefix}bind-username"
                sss_bindpass_parameter    = "/${local.sss_parameter_prefix}bind-password"

                ssh_hostkeys_path          = "/${local.ssh_parameter_prefix}"
                ssh_client_alive_interval  = var.shell_idle_timeout
                ssh_client_alive_count_max = 0

                duo_ikey_parameter = "/${local.duo_parameter_prefix}integration-key"
                duo_skey_parameter = "/${local.duo_parameter_prefix}secret-key"
                duo_host_parameter = "/${local.duo_parameter_prefix}hostname"

                cron_allow_parameter = "/${local.cron_parameter_prefix}allow"

                internal_subnets = join(" ", formatlist(
                    "'%s'",
                    data.aws_subnet.internal[*].cidr_block,
                ))

                extra_enis_table_id = join(" ", formatlist(
                    "[device-number-%d.%d]='%s'",
                    [ for c in local.extra_enis : c.device_index ],
                    [ for c in local.extra_enis : c.network_card_index ],
                    [ for c in local.extra_enis : c.table_id ],
                ))
                extra_enis_prefix_list_ids = join(" ", formatlist(
                    "[device-number-%d.%d]='%s'",
                    [ for c in local.extra_enis : c.device_index ],
                    [ for c in local.extra_enis : c.network_card_index ],
                    [ for c in local.extra_enis : join(" ", c.prefix_list_ids) ],
                ))

                falcon_sensor_package  = var.falcon_sensor_package == null ? "" : var.falcon_sensor_package
                falcon_sensor_cid_path = "/${local.falcon_sensor_parameter_prefix}CID"

                ossec_whitelists_path = "/${local.ossec_parameter_prefix}whitelists"
            }
        )
    }

    part {
        filename     = "includes1.txt"
        content_type = "text/x-include-url"
        content = <<EOF
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/init.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/swap.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/efs.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/network.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/extra-enis.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/ec2logs.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/resolv.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/ssh.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/sss.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/duo.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/cron.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/falcon-sensor.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/ossec.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/cis.sh
EOF
    }

    part {
        filename     = "config-bastion.yml"
        content_type = "text/cloud-config"
        content      = templatefile("templates/config-bastion.yml", {
            hostname = var.hostname
        })
    }

    dynamic "part" {
        for_each = length(local.assets_extra_scripts) == 0 && local.assets_extra_config == null ? [] : [
            concat(
                keys(local.assets_extra_scripts),
                local.assets_extra_config == null ? [] : [ "config.yml" ],
            )
        ]

        content {
            filename     = "includes-extra.txt"
            content_type = "text/x-include-url"
            content = join("\n", formatlist(
                "https://%s/cloud-init/extra/%s",
                aws_s3_bucket.assets.bucket_regional_domain_name,
                part.value,
            ))
        }
    }
}

# =========================================================
# Locals
# =========================================================

locals {
    asg_name            = local.name
    instance_name       = local.name
    security_group_name = local.name
}

# =========================================================
# Resources
# =========================================================

resource "aws_security_group" "bastion" {
    name_prefix = local.name_prefix
    description = "Bastion host group."
    vpc_id      = local.vpc_id

    dynamic "ingress" {
        for_each = var.allowed_cidrs
        content {
            description = "SSH (${ingress.key})"

            protocol  = "tcp"
            from_port = 22
            to_port   = 22

            cidr_blocks      = ingress.value.ipv4
            ipv6_cidr_blocks = ingress.value.ipv6
        }
    }

    dynamic "ingress" {
        for_each = var.allowed_cidrs_codebuild == null ? [] : [ var.allowed_cidrs_codebuild ]
        content {
            description = "SSH"

            protocol  = "tcp"
            from_port = 22
            to_port   = 22

            cidr_blocks = ingress.value
        }
    }

    ingress {
        description = "SSH (${local.vpc_id})"

        protocol  = "tcp"
        from_port = 22
        to_port   = 22

        cidr_blocks      = [ data.aws_vpc.main.cidr_block ]
        ipv6_cidr_blocks = data.aws_vpc.main.ipv6_cidr_block == null ? null : [ data.aws_vpc.main.ipv6_cidr_block ]
    }

    dynamic "ingress" {
        for_each = data.aws_ip_ranges.ec2_instance_connect.cidr_blocks

        content {
            description = "EC2 Instance Connect (console)"

            protocol  = "tcp"
            from_port = 22
            to_port   = 22

            cidr_blocks = [ ingress.value ]
        }
    }

    dynamic "ingress" {
        for_each = data.aws_ip_ranges.ec2_instance_connect.ipv6_cidr_blocks

        content {
            description = "EC2 Instance Connect (console)"

            protocol  = "tcp"
            from_port = 22
            to_port   = 22

            ipv6_cidr_blocks = [ ingress.value ]
        }
    }

    ingress {
        description = "IPv6 support"

        protocol  = "icmpv6"
        from_port = -1
        to_port   = -1

        ipv6_cidr_blocks = [ "::/0" ]
    }

    egress {
        from_port = 0
        to_port   = 0
        protocol  = "-1"

        cidr_blocks      = [ "0.0.0.0/0" ]
        ipv6_cidr_blocks = [ "::/0" ]
    }

    tags = {
        Name = local.security_group_name
    }
}

resource "aws_launch_template" "bastion" {
    name_prefix = local.name_prefix
    description = "Bastion host configuration"

    image_id      = data.aws_ami.amazon_linux2023.id
    instance_type = var.instance_type
    iam_instance_profile {
        name = aws_iam_instance_profile.bastion.name
    }
    credit_specification {
        cpu_credits = substr(var.instance_type, 0, 2) == "t3" || substr(var.instance_type, 0, 2) == "t2" ? "unlimited" : "standard"
    }
    monitoring {
        enabled = var.enhanced_monitoring
    }

    key_name               = var.key_name
    vpc_security_group_ids = concat(
        [ aws_security_group.bastion.id ],
        [ for s in values(data.aws_security_group.bastion_extra) : s.id ],
    )
    user_data              = data.cloudinit_config.bastion_userdata.rendered
    update_default_version = true

    block_device_mappings {
        device_name = "/dev/xvda"

        ebs {
            delete_on_termination = true
            volume_size           = 30
            volume_type           = "gp3"

            encrypted  = true
            kms_key_id = aws_kms_key.data.arn
        }
    }

    tag_specifications {
        resource_type = "instance"
        tags = merge(
            local.default_tags,
            {
                Name       = local.instance_name
                PatchGroup = aws_ssm_patch_group.bastion.patch_group
            },
        )
    }

    tag_specifications {
        resource_type = "volume"
        tags = merge(
            local.default_tags,
            { Name = "${local.name_prefix}root" },
        )
    }

    tags = {
        Name = local.name
    }

    lifecycle {
        create_before_destroy = true
    }
}

resource "aws_autoscaling_group" "bastion" {
    depends_on = [
        time_sleep.bastion_role,
        aws_efs_mount_target.sharedfs,
        aws_eip.bastion,
        aws_cloudwatch_event_target.lambda_associateEIP_BastionInitializationStatus,
        aws_cloudwatch_event_target.lambda_addExtraENIs_BastionInitializationStatus,
        aws_cloudwatch_log_group.ec2,
    ]

    name             = local.asg_name
    min_size         = 1
    max_size         = 2
    desired_capacity = 1

    default_cooldown          = 300
    health_check_grace_period = 600
    health_check_type         = "EC2"
    termination_policies = [
        "OldestInstance",
        "OldestLaunchTemplate",
    ]

    vpc_zone_identifier = local.public_subnet_ids

    launch_template {
        id      = aws_launch_template.bastion.id
        version = aws_launch_template.bastion.latest_version
    }

    lifecycle {
        precondition {
            condition     = length(setsubtract(local.public_subnet_azs, local.internal_subnet_azs)) == 0
            error_message = "Not all internal subnets are in the same availability zones as the public subnets."
        }
    }
}
