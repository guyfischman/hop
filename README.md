# hop

An IP address in an AWS region of your choice, on demand. `hop up` launches a
throwaway EC2 instance that joins your tailnet as an exit node and routes this
Mac through it; `hop down` removes the instance, its security group and its
tailnet device.

```
hop up eu-west-2            # prints: <hostname> <region> <public ip>
hop status                  # running nodes, and which one is in use
hop down                    # destroy every node; or: hop down eu-west-2
hop regions                 # regions the AWS account can launch in
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

One `t4g.micro` (or `t3.micro` where the region has no Graviton) running the
current Amazon Linux 2023 image, with no key pair, no instance role, IMDSv2
only, and a security group that admits UDP 41641 and nothing else. hop keeps
no state on disk: a node is any instance carrying the `hop` tag.

## Tests

```sh
tests/run.sh
```

The suite replaces `aws`, `tailscale`, `curl` and `security` with stubs, so it
launches nothing and needs no credentials.
