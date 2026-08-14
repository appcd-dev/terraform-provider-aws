package policy

import rego.v1

# Guild governance contract: a "logic" policy must expose allow/deny. Read-only
# work is allowed by default; destructive or off-hours high-risk shell is denied
# so it is gated for human review instead of running autonomously.
default allow := true

default deny := false

# Nanoseconds since epoch for input.timestamp (RFC3339). Undefined when missing/invalid.
factsheet_ts_ns := time.parse_rfc3339_ns(ts) if {
	ts := object.get(input, "timestamp", "")
	ts != ""
}

# Weekend or 22:00–07:59 UTC — fewer humans online; tighten shell governance.
off_staff_hours if {
	ns := factsheet_ts_ns
	time.weekday(ns) in {"Saturday", "Sunday"}
}

off_staff_hours if {
	ns := factsheet_ts_ns
	hour := time.clock(ns)[0]
	utc_low_traffic_hour(hour)
}

utc_low_traffic_hour(h) if h < 8

utc_low_traffic_hour(h) if h >= 22

# Gate destructive shell patterns: rm -rf, force-delete, terraform destroy, etc.
deny if {
	endswith(input.tool.name, "_execute_command")
	cmd := lower(input.tool.arguments.command)
	destructive_pattern(cmd)
}

destructive_pattern(cmd) if contains(cmd, "rm -rf")

destructive_pattern(cmd) if contains(cmd, "force-delete")

destructive_pattern(cmd) if contains(cmd, "terraform destroy")

destructive_pattern(cmd) if contains(cmd, "tofu destroy")

destructive_pattern(cmd) if contains(cmd, "kubectl delete")

destructive_pattern(cmd) if contains(cmd, "helm uninstall")

destructive_pattern(cmd) if contains(cmd, "helm delete")

destructive_pattern(cmd) if contains(cmd, "aws iam delete")

destructive_pattern(cmd) if contains(cmd, "aws ec2 terminate")

destructive_pattern(cmd) if contains(cmd, "drop table")

destructive_pattern(cmd) if contains(cmd, "drop database")

destructive_pattern(cmd) if contains(cmd, "truncate ")

destructive_pattern(cmd) if contains(cmd, "mkfs")

destructive_pattern(cmd) if contains(cmd, "dd if=")

# Off-hours: catch common supply-chain / privilege-escalation footguns in shell.
deny if {
	off_staff_hours
	endswith(input.tool.name, "_execute_command")
	cmd := lower(input.tool.arguments.command)
	elevated_risk_shell(cmd)
}

elevated_risk_shell(cmd) if {
	contains(cmd, "chmod")
	contains(cmd, "777")
}

elevated_risk_shell(cmd) if {
	contains(cmd, "git push")
	contains(cmd, " --force")
}

elevated_risk_shell(cmd) if {
	contains(cmd, "git push")
	contains(cmd, " -f ")
}

elevated_risk_shell(cmd) if {
	contains(cmd, "curl")
	contains(cmd, "| sh")
}

elevated_risk_shell(cmd) if {
	contains(cmd, "wget")
	contains(cmd, "| bash")
}

elevated_risk_shell(cmd) if {
	contains(cmd, "curl")
	contains(cmd, "| bash")
}

deny_reason := "Destructive or off-hours high-risk shell command requires human approval" if {
	deny
}
