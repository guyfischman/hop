# hop

An IP address in an AWS region, Local Zone or Wavelength Zone of your choice,
on demand. `hop up` launches a
throwaway EC2 instance that joins your tailnet as an exit node and routes this
Mac through it; `hop down` removes the instance, its security group and its
tailnet device.

```
hop up eu-west-2            # prints: <hostname> <region> <public ip>
hop status                  # running nodes, and which one is in use
hop down                    # destroy every node; or: hop down eu-west-2
hop regions                 # regions the AWS account can launch in
hop zones                   # Local and Wavelength Zones under those regions
hop up us-east-1-bue-1a     # Buenos Aires (Local Zone)
hop up ca-central-1-wl1-yto-wlz-1   # Toronto (Wavelength Zone, Bell's network)
hop doctor                  # check tools, credentials and Tailscale access
```

A node destroys itself after 8 hours even if `down` never runs. Change that
per launch with `--ttl HOURS` or for good with `HOP_TTL_HOURS`.

## Requirements

`aws` (v2), `tailscale`, `curl`, `jq` and `openssl` on the PATH, and Tailscale
running on this Mac. The script runs under the stock macOS bash.

## Setup

1. In the tailnet policy file, define the tag and let it approve itself as an
   exit node:

   ```json
   "tagOwners": {
     "tag:hop": [],
   },
   "autoApprovers": {
     "exitNode": ["tag:hop"],
   },
   ```

   Then keep the node out of the rest of the tailnet. Tailscale denies
   whatever no rule allows, but the default allow-all rule has `*` as its
   source, and `*` includes tagged devices. Give every rule a source that
   names people, not `*`, and add a test so the policy file refuses to save
   if a node could ever reach one of your machines:

   ```json
   "grants": [
     {"src": ["autogroup:member"], "dst": ["*"], "ip": ["*"]},
     {"src": ["autogroup:member"], "dst": ["autogroup:internet"], "ip": ["*"]},
   ],
   "tests": [
     {"src": "tag:hop", "deny": ["<tailnet IP of one of your machines>:22"]},
   ],
   ```

2. Create a Tailscale OAuth client with the `auth_keys` and `devices:core`
   scopes (write), both restricted to `tag:hop`. Store it in the Keychain;
   each command prompts for the value:

   ```sh
   security add-generic-password -U -s hop -a ts-oauth-client-id -w
   security add-generic-password -U -s hop -a ts-oauth-client-secret -w
   ```

   `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_CLIENT_SECRET` in the environment take
   precedence over the Keychain.

3. Name the AWS CLI profile to launch into, in `~/.config/hop/env`:

   ```sh
   HOP_AWS_PROFILE=personal
   ```

4. Run `hop doctor`.

## AWS permissions

The profile's identity needs, on EC2: `RunInstances`, `TerminateInstances`,
`CreateTags`, `DescribeInstances`, `DescribeRegions`, `DescribeVpcs`,
`DescribeInstanceTypeOfferings`, `DescribeSecurityGroups`,
`CreateSecurityGroup`, `AuthorizeSecurityGroupIngress`, `DeleteSecurityGroup`,
`GetConsoleOutput`; and `ssm:GetParameters` on
`arn:aws:ssm:*::parameter/aws/service/ami-amazon-linux-latest/*`.

The region needs a default VPC. Opt-in regions must be enabled on the account
before `hop regions` lists them.

## What a node is

The smallest instance the target offers, running the current Amazon Linux
2023 image, with no key pair, no instance role, IMDSv2
only, and a security group that admits UDP 41641 and nothing else. hop keeps
no state on disk: a node is any instance carrying the `hop` tag.

At launch hop lists every instance type the region or zone offers and ranks
them by memory, then Graviton before x86, then vCPUs, with GPU types last.
It takes the first with at least `HOP_MIN_MEMORY_MIB` (default 512) and moves
down the list if a launch fails for lack of capacity. In a full region that
is `t4g.nano`; it also needs `ec2:DescribeInstanceTypes`.

## Zones

Countries without a full region are often covered by a zone attached to one.
`hop up <zone>` enables the zone on the account the first time (a few
minutes), creates a small subnet for it in the parent region's default VPC,
and `hop down <zone>` removes the subnet again along with every node in that
parent region. The zone stays enabled on the account.

Zones offer few instance sizes, often nothing below `t3.medium`, and the
small ones can be out of capacity, so hop moves up until a launch succeeds. Check `hop status` for
the size you got; a larger one costs more per hour.

A Wavelength Zone sits inside a mobile carrier's network. The node reaches
the internet through a carrier gateway, websites see the carrier's address
and not an Amazon one, and nothing on the internet can connect in, so
Tailscale relays the traffic and it is slower than a direct connection.

The identity also needs `ModifyAvailabilityZoneGroup`,
`DescribeAvailabilityZones`, `CreateSubnet`, `DeleteSubnet`,
`DescribeSubnets`, and for Wavelength `CreateCarrierGateway`,
`DeleteCarrierGateway`, `DescribeCarrierGateways`, `CreateRouteTable`,
`CreateRoute`, `AssociateRouteTable`, `DeleteRouteTable` and
`DescribeRouteTables`.

## Tests

```sh
tests/run.sh
```

The suite replaces `aws`, `tailscale`, `curl` and `security` with stubs, so it
launches nothing and needs no credentials.
