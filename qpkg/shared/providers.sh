# DNS providers LegoCert offers by name. Data only (sourced by common.sh, the
# settings page and tests/lego-flags.sh), so the list can't drift between them.
# Any other lego provider works through "Other" (its code + its variables).
#
# Adding one: an entry in each function below, setup steps in ui/index.cgi
# (provider_steps), and run `make lego-flags e2e`: CI checks every field here
# against the real lego.

PROVIDERS="cloudflare duckdns porkbun route53 digitalocean hetzner ovh gandiv5 desec"

provider_label() { # provider_label CODE
	case $1 in
	cloudflare) echo Cloudflare ;;
	duckdns) echo DuckDNS ;;
	porkbun) echo Porkbun ;;
	route53) echo "AWS Route 53" ;;
	digitalocean) echo DigitalOcean ;;
	hetzner) echo Hetzner ;;
	ovh) echo OVHcloud ;;
	gandiv5) echo Gandi ;;
	desec) echo deSEC ;;
	*) echo "$1" ;;
	esac
}

# provider_fields CODE: one line per field, VAR|KIND|Label
#   VAR   the lego environment variable (`lego dnshelp --code CODE`)
#   KIND  secret (write-only in the UI), text (shown), optional (text, may be
#         empty), ovh-endpoint (a choice)
provider_fields() {
	case $1 in
	cloudflare) echo "CLOUDFLARE_DNS_API_TOKEN|secret|API token" ;;
	duckdns) echo "DUCKDNS_TOKEN|secret|Token" ;;
	porkbun) printf '%s\n' "PORKBUN_API_KEY|secret|API key" "PORKBUN_SECRET_API_KEY|secret|Secret key" ;;
	route53) printf '%s\n' "AWS_ACCESS_KEY_ID|text|Access key ID" "AWS_SECRET_ACCESS_KEY|secret|Secret access key" "AWS_HOSTED_ZONE_ID|optional|Hosted zone ID" ;;
	digitalocean) echo "DO_AUTH_TOKEN|secret|API token" ;;
	hetzner) echo "HETZNER_API_TOKEN|secret|API token" ;;
	ovh) printf '%s\n' "OVH_ENDPOINT|ovh-endpoint|Region" "OVH_APPLICATION_KEY|text|Application key" "OVH_APPLICATION_SECRET|secret|Application secret" "OVH_CONSUMER_KEY|secret|Consumer key" ;;
	gandiv5) echo "GANDIV5_PERSONAL_ACCESS_TOKEN|secret|Personal access token" ;;
	desec) echo "DESEC_TOKEN|secret|Token" ;;
	esac
}

# Variables a provider also accepts in legocert.conf without showing them in the UI
# (older or advanced settings).
provider_extra_vars() {
	case $1 in
	cloudflare) echo CLOUDFLARE_ZONE_API_TOKEN ;;
	esac
}

is_known_provider() { # is_known_provider CODE
	case " $PROVIDERS " in *" $1 "*) [ -n "$1" ] ;; *) return 1 ;; esac
}
