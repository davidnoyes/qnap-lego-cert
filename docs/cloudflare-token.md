# Creating the Cloudflare API token

LegoCert proves to Let's Encrypt that you control the NAS's name by creating a temporary TXT
record (`_acme-challenge.<your NAS name>`) through the Cloudflare API. It needs an API token
to do that. This page shows how to create one that can do as little as possible.

## What Cloudflare can and can't restrict

A Cloudflare API token can be limited to:

- **one zone** (one domain, such as `example.com`);
- **specific permissions** (here: edit DNS records, read the zone);
- **specific client IP addresses** (your home connection);
- **a validity period**.

It **can't** be limited to one DNS name. Cloudflare scopes tokens by zone; record-level
scoping is a long-standing open feature request. So a token for `example.com` can edit
*every* record in it: your website, email (MX), everything. If such a token leaked, someone
could take over the domain.

LegoCert's token is therefore scoped to your domain's zone, and the other limits do the work:

- **Two permissions only** (edit DNS records, read the zone). It can't touch anything else
  on your Cloudflare account: no other zones, settings, caching or billing.
- **Your home IP address only** (optional, recommended). A copy of the token used from
  anywhere else is refused.
- **A token of its own**, used for nothing else, so you can revoke it without breaking
  anything.

The token lives only on the NAS, in a file only root can read (see the README).

## Creating the token

1. Sign in to the Cloudflare dashboard and open **My Profile → API Tokens**
   (`dash.cloudflare.com/profile/api-tokens`), then **Create Token**. Use a token from your own
   profile ("user token"): `renew.sh --check-token` checks that kind.
2. **Token name**: something that says where it lives, e.g. `LegoCert NAS`.
3. **Policies**: set `Include` → `Specific zone` → your domain (e.g. `example.com`).
   **Never** "All zones".
4. **Permissions**: open the **DNS & Zones** group and tick exactly two boxes:

   | Permission | Read | Edit |
   |---|---|---|
   | DNS | | ✓ |
   | Zone | ✓ | |

   lego needs *Zone Read* to look up the zone, and *DNS Edit* to add and remove the
   challenge record. Tick nothing else.
5. **Token expiration**: leave it empty. A token that expires silently stops renewals; LegoCert
   would report it, but nothing gains from building that in. If you do set an end date, put
   a reminder in your calendar a month earlier.
6. **Client IP Address Filtering** (optional, recommended): `Is in` → your home internet
   address(es).
   - Your IPv4 address is your router's WAN address (in the router's status page).
   - If the NAS has IPv6 internet access, its API calls may go out over IPv6, so add your
     IPv6 prefix too (e.g. `2a02:xxxx:xxxx::/48`). Otherwise the token works on some days
     and not others.
   - If your ISP changes your address, renewals start failing. LegoCert reports that as a
     warning, then an error well before expiry. Update the filter when it happens.
7. **Review**. The summary should read like:
   `example.com – DNS:Edit, Zone:Read`, plus your IP filter if you added one. One zone, two permissions.
8. **Create the token** and **copy it now**: Cloudflare shows it only once. New tokens
   start with `cfut_`. Don't paste it into chat, email or tickets; it goes straight into the
   NAS config in the next step.

## Putting it on the NAS

Over SSH as admin:

```sh
sudo -i
cd "$(getcfg LegoCert Install_Path -f /etc/config/qpkg.conf)"
vi legocert.conf                 # set CLOUDFLARE_DNS_API_TOKEN=<token>
ls -l legocert.conf              # must show -rw------- root
./renew.sh --check-token
```

`--check-token` asks Cloudflare whether the token is active and which zones it can see,
without changing anything. Example:

```
token: active
zones this token can see (1): example.com
OK: the token is limited to a single zone.
```

| If it says | Then |
|---|---|
| `token: NOT active` / `Invalid API Token` | wrong or revoked token: copy it again |
| an IP-related error (Cloudflare code 9109) | the NAS's public address isn't in the token's IP filter; add it, including IPv6 if used |
| `can see 0 zones` | *Zone Read* is missing, or the zone resource is wrong |
| `can see N zones` (N > 1) | the token isn't limited to one zone: recreate it with *Specific zone* |

Then run the staging dry run (`./renew.sh --staging`) as in the README.

## Rotating or revoking

- **Rotate:** create a new token as above, replace it in `legocert.conf`, run
  `./renew.sh --check-token`, then delete the old token in the dashboard.
- **Revoke** (NAS lost, app removed, token exposed): My Profile → API Tokens → ⋯ → Delete.
  If you think it was used, also check the zone's DNS records for anything you didn't add.

## Optional: limiting the token further with a validation zone

Not needed for normal use; noted here for completeness. If you want a leaked token to be
unable to change your main domain at all, give the challenge record its own zone:

1. Add a second, otherwise unused domain to Cloudflare (free plan), e.g. `example-acme.net`.
2. In your main zone, add a **CNAME**, set to **DNS only** (grey cloud):
   `_acme-challenge.nas.int` → `nas-int-example-com.example-acme.net`.
3. Create the token as above, but scoped to `example-acme.net`.

lego follows the CNAME by itself and writes the challenge record in the validation zone. A
leaked token could then only get certificates for the NAS name, not edit your domain. The
cost is a second domain and a less common setup that's harder to understand later.
