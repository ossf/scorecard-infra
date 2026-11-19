# DNS

Authoritative DNS delegation for `scorecard.dev` and `securityscorecards.dev` is
managed through [Netlify DNS](https://www.netlify.com/platform/core/dns/) (backed
by NS1 infrastructure). Domain registrations are held by the Linux Foundation.

## Nameservers

Delegation moved from Google Cloud DNS to Netlify DNS at the registrar level
(LF IT ticket IT-30079). Each zone uses its own nameserver pool:

### scorecard.dev (p01 pool)
* `dns1.p01.nsone.net`
* `dns2.p01.nsone.net`
* `dns3.p01.nsone.net`
* `dns4.p01.nsone.net`

### securityscorecards.dev (p09 pool)
* `dns1.p09.nsone.net`
* `dns2.p09.nsone.net`
* `dns3.p09.nsone.net`
* `dns4.p09.nsone.net`

## Website

The static website is deployed from [`ossf/scorecard-webapp`](https://github.com/ossf/scorecard-webapp)
and hosted on Netlify. The apex domains and `www` subdomains resolve directly to
Netlify's edge infrastructure.

## Results API

The API serving path no longer runs on Cloud Run or uses Cloud Run domain
mappings. Production and staging traffic is fronted by Fastly and backed by AWS:

```text
api.scorecard.dev          ──┐
                             ├─> Fastly CDN (x.sni.global.fastly.net)
api.securityscorecards.dev ──┘     └─> AWS ALB origin (deploy/api)
                                         └─> ECS Fargate (results API)
```

* In Netlify DNS, both production hostnames (`api.scorecard.dev`,
  `api.securityscorecards.dev`) and staging hostnames (`api-staging.scorecard.dev`,
  `api-staging.securityscorecards.dev`) are `CNAME` records pointing to
  `x.sni.global.fastly.net` (300s TTL). Fastly terminates edge TLS and enforces
  `Surrogate-Control` cache lifetimes. TLS certificate renewal challenges
  (`_acme-challenge`) delegate to `*.fastly-validations.com` via CNAMEs in
  Netlify DNS.
* Fastly proxies origin requests to an Application Load Balancer (ALB) deployed
  in AWS via OpenTofu in [`deploy/api/`](../deploy/api/). The ALB terminates
  TLS with an AWS Certificate Manager (ACM) certificate whose DNS validation
  records are created in Netlify DNS. The ALB forwards traffic to ECS Fargate
  tasks running the `api/` container.

Traffic shifts and cutovers are Fastly backend changes, not DNS record
repoints (see `openspec/changes/migrate-api/tasks.md` 6.3c).
