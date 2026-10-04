# hop

cli to turn up an ephemeral exit node on your tailnet at an AWS region, Local
Zone, or Wavelength Zone of your choice.

```
hop up [region]             # turns up node and routes your mac through it
hop up [region] --spot      # spot pricing, interruptible instance
hop up [region] --ttl 2     # use non-default (8 hours) ttl
hop up 
hop status                  # running nodes, and which one is in use; --json for scripts
hop down                    # destroy every node
hop down [region]           # destroy one node
hop regions                 # regions the AWS account can launch in
hop zones                   # Local and Wavelength Zones under those regions
hop doctor                  # check tools, credentials and Tailscale access
```

A watcher pings the exit node and if down restores the mac's network access.
This is a convenience script - if you need anonymity and a kill switch then you
need something else.

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
   "acls": [
     {"action": "accept", "src": ["autogroup:member"], "dst": ["*:*"]},
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

The profile's identity needs these actions.

| For | Actions |
| --- | --- |
| Every launch | `ec2:RunInstances`, `TerminateInstances`, `CreateTags`, `DescribeInstances`, `DescribeRegions`, `DescribeVpcs`, `DescribeSubnets`, `DescribeRouteTables`, `DescribeCarrierGateways`, `DescribeSecurityGroups`, `CreateSecurityGroup`, `AuthorizeSecurityGroupIngress`, `DeleteSecurityGroup`, `GetConsoleOutput`; `ssm:GetParameters` on `arn:aws:ssm:*::parameter/aws/service/ami-amazon-linux-latest/*` |
| Choosing the cheapest type | `ec2:DescribeInstanceTypeOfferings`, `DescribeInstanceTypes`; `pricing:GetProducts`; for `--spot`, `ec2:DescribeSpotPriceHistory` |
| Local and Wavelength Zones | `ec2:DescribeAvailabilityZones`, `ModifyAvailabilityZoneGroup`, `CreateSubnet`, `DeleteSubnet` |
| Wavelength Zones only | `ec2:CreateCarrierGateway`, `DeleteCarrierGateway`, `CreateRouteTable`, `CreateRoute`, `AssociateRouteTable`, `DeleteRouteTable` |

The region needs a default VPC. Opt-in regions must be enabled on the account
before `hop regions` lists them.
