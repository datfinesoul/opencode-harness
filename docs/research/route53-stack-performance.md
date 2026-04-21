# Improving OpenTofu / Terraform Performance for AWS Route 53 Stacks

## Problem

A stack containing a few hundred `aws_route53_record` resources in a single
hosted zone takes an extremely long time to `plan` and `apply`. This is a
well-documented, long-standing limitation of the AWS provider, not a problem
specific to your code.

Two things compound to make it slow:

1. **One AWS API call per record.** `aws_route53_record` is a "singular"
   resource. Every record is a separate `ChangeResourceRecordSets` and a
   separate `ListResourceRecordSets` round-trip during refresh. With ~200
   records in one zone you very quickly hit Route 53's per-account API rate
   limit (5 req/s combined across the account), at which point the AWS SDK
   starts retrying with exponential backoff and the run grinds to a crawl.
2. **Refresh dominates `plan`.** Even if nothing changed, every record is
   re-read from the API on each plan. With throttling, "nothing to do" plans
   can take an hour. The 2018 Stack Overflow report (Igor) of 1h+ plans on
   ~1000 records is the canonical example, and the same pattern still applies
   today, just at a higher absolute record count before it bites.

References:
- HashiCorp issue [#3230](https://github.com/hashicorp/terraform-provider-aws/issues/3230)
  – original "aggregate Route 53 changes into one request" feature request (2018, still open for `aws_route53_record`).
- HashiCorp issue [#40466](https://github.com/hashicorp/terraform-provider-aws/issues/40466)
  – the formal admission that `aws_route53_record` "has scaling issues which
  can lead to problems with rate limiting and can make it unsuitable for
  managing large sets of records for a zone."
- Stack Overflow [#53560266](https://stackoverflow.com/questions/53560266/terraform-throttling-route53)
  – throttling symptoms and partial mitigations.

---

## Recommended fix: `aws_route53_records_exclusive` (provider ≥ 5.91)

This is the resource HashiCorp added specifically to solve your problem.
Available in both the [Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_records_exclusive)
and the [OpenTofu Registry](https://search.opentofu.org/provider/hashicorp/aws/latest/docs/resources/route53_records_exclusive).

### What it does

A single resource owns **all** record sets for one hosted zone (NS / SOA at the
apex are automatically excluded). It uses the batched `ChangeResourceRecordSets`
API, so:

- One `ListResourceRecordSets` (paginated) replaces N reads on refresh.
- One batched change request per apply replaces up to N create/update calls.
  Route 53 allows up to 1000 changes / 32000 characters per batch, which is far
  larger than typical stacks.
- Plans no longer trigger 200+ rate-limited GETs.

Real-world reports show plan/apply for a few hundred records dropping from
tens of minutes (or hours when throttled) to well under a minute.

### Caveats — read these before adopting it

1. **Exclusive ownership.** Anything in the zone that is not declared in the
   resource will be **deleted** on apply. That includes records created
   manually, by other stacks, or by other tools (cert-manager, external-dns,
   ACM validation records, SES, etc.). Inventory the zone first.
2. **NS and SOA at the apex are ignored** by the resource — do not put them
   in `resource_record_set` blocks or you will get persistent drift.
3. **No mixing on the same zone.** You can technically keep some
   `aws_route53_record` resources alongside it, but every record managed
   elsewhere must be mirrored as a `resource_record_set` block here, otherwise
   it gets nuked on every apply. In practice: one zone → one exclusive resource.
4. **Different schema.** Migration is not a simple `moved` block. The nested
   `resource_record_set { ... }` schema differs from `aws_route53_record`
   (e.g. `resource_records { value = "..." }` blocks instead of a `records = [...]`
   list). You import by `zone_id` and then re-shape your HCL.
5. **Provider version.** Requires `hashicorp/aws` ≥ 5.91.0 (Feb 2025).
6. **Timeouts default to 45 minutes** for create/update — fine for huge
   zones but worth being aware of.

### Migration outline

1. Pin `hashicorp/aws` to ≥ 5.91 in the stack.
2. Audit the hosted zone (`aws route53 list-resource-record-sets`) and
   reconcile every record against your HCL. Excluded records will be deleted.
3. Convert your `for_each` / list of `aws_route53_record` into a single
   `aws_route53_records_exclusive` with one `resource_record_set` block per
   record. Local values + a `dynamic "resource_record_set"` block keeps the
   HCL roughly the same shape as today.
4. `tofu state rm` the old `aws_route53_record` resources, or use `removed`
   blocks (OpenTofu 1.7+) so state is dropped without deleting the records in
   AWS.
5. `tofu import` (or an `import` block) the exclusive resource by `zone_id`.
6. Run `tofu plan` — should be a no-op. If not, fix the diffs before applying.

### Example shape

```hcl
locals {
  records = {
    "api"    = { type = "A",     ttl = 60,  values = ["10.0.0.1"] }
    "www"    = { type = "CNAME", ttl = 300, values = ["api.example.com"] }
    # ... ~200 entries
  }
}

resource "aws_route53_records_exclusive" "main" {
  zone_id = aws_route53_zone.main.zone_id

  dynamic "resource_record_set" {
    for_each = local.records
    content {
      name = "${resource_record_set.key}.example.com"
      type = resource_record_set.value.type
      ttl  = resource_record_set.value.ttl

      dynamic "resource_records" {
        for_each = resource_record_set.value.values
        content { value = resource_records.value }
      }
    }
  }
}
```

---

## If you cannot adopt the exclusive resource

In rough order of impact:

### 1. Stop refreshing on every plan
- Use `-refresh=false` for routine plans, and only refresh on a schedule
  (e.g. nightly drift check). This skips the per-record `ListResourceRecordSets`
  calls entirely. In OpenTofu Stacks you can drive this via the orchestration
  layer rather than per-component.
- For targeted changes, `-target=...` to scope work down to a few records.

### 2. Provider tuning
In the `provider "aws"` block:
```hcl
provider "aws" {
  max_retries              = 25
  retry_mode               = "adaptive"   # AWS SDK adaptive backoff
}
```
And cap concurrency at the CLI:
```
tofu plan  -parallelism=5
tofu apply -parallelism=5
```
Throttling gets worse, not better, with high parallelism on Route 53.

### 3. Split the zone across multiple stacks / states
Each state refreshes independently and in parallel. Splitting one giant zone
across 4 components of ~50 records each significantly reduces per-run
wall-clock time (though total API calls are unchanged). With OpenTofu Stacks
this is natural — model each logical group of records as its own component.

### 4. Drop unused / dead records
Often the cheapest win. Many large zones contain hundreds of records that
were created for one-off projects and never deleted.

### 5. Increase TTLs / consolidate
Not a tofu performance fix per se, but reduces churn-driven applies.

---

## Alternatives outside the AWS provider

If the AWS provider's record model is fundamentally a bad fit (e.g. you have
thousands of records, frequently bulk-edit, or want zone-file ergonomics),
the community generally moves DNS out of Terraform/OpenTofu entirely:

- **[octoDNS](https://github.com/octodns/octodns)** (GitHub / Sponsors). YAML
  zone files, batched provider APIs, dry-run diffs that look like a `tofu plan`,
  multi-provider. Designed for managing tens of thousands of records.
  Commonly paired with Tofu: Tofu owns the hosted zone + delegation, octoDNS
  owns the records.
- **[DNSControl](https://docs.dnscontrol.org/)** (Stack Exchange). JavaScript
  DSL, similar philosophy and batched APIs, also multi-provider.

Both call `ChangeResourceRecordSets` in batches and complete in seconds for
zones the size of yours.

---

## Recommendation for your case (~200 records, OpenTofu Stacks)

1. **Primary:** migrate the zone to a single `aws_route53_records_exclusive`
   resource. This is the lowest-friction fix that stays inside OpenTofu and
   eliminates the root cause (singular API calls + refresh-on-every-plan).
2. **Immediately, while planning the migration:** bump
   `provider.aws.max_retries`, set `retry_mode = "adaptive"`, drop
   `-parallelism` to 5, and run routine plans with `-refresh=false`, with a
   scheduled refresh job for drift detection.
3. **Only consider octoDNS / DNSControl** if you already have, or expect to
   have, zones an order of magnitude larger, or if multiple non-AWS DNS
   providers are in play.

## Sources

- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_records_exclusive
- https://search.opentofu.org/provider/hashicorp/aws/latest/docs/resources/route53_records_exclusive
- https://github.com/hashicorp/terraform-provider-aws/issues/40466
- https://github.com/hashicorp/terraform-provider-aws/issues/3230
- https://stackoverflow.com/questions/53560266/terraform-throttling-route53
- https://docs.aws.amazon.com/Route53/latest/APIReference/API_ChangeResourceRecordSets.html
- https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/DNSLimitations.html
- https://github.com/octodns/octodns
- https://docs.dnscontrol.org/
