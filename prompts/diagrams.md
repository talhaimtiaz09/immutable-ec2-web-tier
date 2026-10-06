# Diagram prompts

Three images for `docs/index.html`. Same style as the portfolio case studies
(`~/Desktop/portfolio/prompts/diagrams/style.md`).

1. New ChatGPT chat. Paste the **Style block**, wait for the confirmation.
2. Paste the **Context** block. ChatGPT replies "got it" and draws nothing.
3. Send each diagram prompt as its own message.
4. Save each image to its "Save as" path. Until a file exists, the page shows a dashed slot.

Check every label letter by letter. Watch `lab.tfvars`, `ami_id`, `rollout.sh` and `fck-nat`.
For a wrong label, reply: Keep everything exactly the same. Only change the label "X" to "Y".

## Style block (paste first)

```
You are a Diagram Architect AI. Every diagram in this chat follows this style exactly.

1. Canvas: landscape 3:2. Off-white background with a subtle light-grey graph-paper grid.
2. Strokes: hand-drawn, sketchy lines, slightly rough, like Excalidraw.
3. Shapes:
   - Dashed rounded boxes with light pastel fills group zones:
     pastel green = private / safe / the fix,
     pastel blue = cloud account, region, VPC or cluster,
     pastel purple = people, identity and CI,
     pastel yellow = end users and the product itself,
     pale grey = public internet, or the old / rejected approach.
   - Each service is a small flat 2D icon centred above its label. Use recognisable AWS / Google
     Cloud / Kubernetes / GitHub / GitLab / vendor-style icons where one exists. Generic things
     (person, phone, laptop, globe, database, key, file, shield) get simple flat icons.
4. Typography: a handwritten font (Virgil / Caveat style), dark charcoal. Short labels only.
5. Flow:
   - Dashed arrows show data/access flow.
   - Numbered orange circle badges (1, 2, 3...) mark the order of steps.
   - Small curved annotation arrows point to short inline notes (max 8 words each).
   - A blocked or rejected path is a dashed grey arrow that ends in a red ✕. A rejected box is
     grey and struck through.
   - The fix gets a small green check.
6. Layout: strict alignment, generous white space, nothing crammed.

TEXT RULES: use ONLY the labels I give, spelled exactly as written. No title, no legend, no
watermark, no extra text, no invented numbers, no company or client names.

Next I'll send a short project context, then one diagram per message. Don't generate anything
until I ask for a diagram. Confirm you understand.
```

## Context (paste second)

```
Project context. Don't draw anything yet, just read it and reply "got it".

A personal AWS lab: a small API on a fleet of EC2 instances that are never patched after they
boot. Every change is baked into a new machine image (a "golden AMI"), and the fleet is replaced.

- Network: one VPC, two Availability Zones, three subnet tiers. Public subnets hold the
  Application Load Balancer (ALB) and a small NAT instance called fck-nat. Private app subnets hold
  an Auto Scaling group of EC2 instances. Isolated database subnets hold RDS Postgres.
- Each tier only accepts traffic from the security group of the tier above it: internet → ALB →
  app → database. The database is not public.
- Nobody uses SSH. There is no bastion and no key pair. Operators connect with AWS SSM Session
  Manager, which is authenticated by IAM.
- A release: a build produces a golden AMI tagged with the git commit. CI opens a pull request that
  changes one line, ami_id, in a file called lab.tfvars. A reviewer approves, Terraform creates a
  new launch template version, and a script called rollout.sh starts an Auto Scaling instance
  refresh. GitHub Actions reaches AWS through GitHub OIDC, with no stored AWS keys.
- The instance refresh launches new instances beside the old ones before removing any. If a
  CloudWatch alarm fires (5xx errors or unhealthy hosts), AWS automatically rolls the fleet back
  to the old version.
- The catch: Terraform's built-in instance_refresh saves the new version on the group first, so
  its rollback would redeploy the bad AMI. That's why rollout.sh starts the refresh instead.
```

## Diagram 1 · Hero
Save as `docs/images/ec2-architecture.png`

```
Generate Diagram 1. Story: only the load balancer faces the internet, and each tier only accepts
the tier above it.

FAR LEFT (pastel yellow zone): person icon "Users".

RIGHT: big dashed pastel-blue box "AWS VPC · 2 AZs" containing three horizontal bands, top to
bottom:
- Pale band "Public subnets": ALB icon "ALB" in the middle, small NAT icon "fck-nat" on the right.
- Pastel-green band "Private app subnets": Auto Scaling icon "Auto Scaling group" wrapping two EC2
  icons, each labelled "EC2", note "golden AMI".
- Pastel-green band "Database subnets": RDS icon "RDS Postgres", note "not public".

ARROWS:
- Users → ALB: badge 1, label "HTTPS"
- ALB → Auto Scaling group: badge 2, note "only from ALB"
- Auto Scaling group → RDS Postgres: badge 3, note "only from app"
- Auto Scaling group → fck-nat: thin dashed grey arrow, note "egress only"

BOTTOM LEFT (pastel purple zone): person icon "Operator" → SSM icon "Session Manager" → EC2,
note "no SSH, no port 22". Next to it, a small grey struck-through key icon "SSH key" with a red ✕.

Keep the composition centred with empty graph paper around the edges.
```

## Diagram 2 · Release path
Save as `docs/images/ec2-release-path.png`

```
Generate Diagram 2. Story: a release is a one-line change that a human approves once, and
everything after that is automatic.

ONE ROW, left to right, dashed arrows between each step:
1. Pastel purple: person icon "Engineer", label "commit". badge 1.
2. Pastel purple: GitHub Actions icon "Image build". badge 2.
3. Pastel green: disk/image icon "Golden AMI", note "tagged with git SHA".
4. Pastel purple: pull request icon "PR: ami_id", note "one line in lab.tfvars". badge 3.
5. Pastel purple: person icon with a green check "Reviewer", label "approve". badge 4.
6. Pastel blue: Terraform icon "Terraform", note "new launch template version". badge 5.
7. Pastel blue: Auto Scaling icon "Instance refresh", label "rollout.sh". badge 6.

BELOW the row, under steps 2 to 6: a long thin pastel-purple strip with a GitHub icon
"GitHub OIDC", note "short-lived role, no stored keys". At its right end, a grey struck-through
key icon "AWS access keys" with a red ✕.

Generous space between steps. If the row is too wide, wrap after step 4 into a second row that
continues left to right.
```

## Diagram 3 · Where the rollback lands
Save as `docs/images/ec2-refresh-rollback.png`

```
Generate Diagram 3. Story: the obvious Terraform rollout rolls back to the bad image; starting
the refresh from a script rolls back to the good one.

TWO PANELS SIDE BY SIDE.

LEFT PANEL (pale grey, rejected), heading label "Terraform instance_refresh":
- box "save v2 on group", then arrow to box "refresh", then arrow to a CloudWatch alarm icon
  "alarm fires", then arrow to box "roll back to v2"
- the last box is grey and struck through, with a red ✕ and note "redeploys the bad AMI"

RIGHT PANEL (pastel green, the fix), heading label "rollout.sh":
- top: box "group keeps v1", note "saved until refresh succeeds"
- middle: an Auto Scaling group outline holding four small EC2 squares labelled "v1", "v1", "v2",
  "v2", note "new beside old"
- a CloudWatch alarm icon "alarm fires" with small labels "5xx" and "unhealthy hosts"
- bottom: arrow from the alarm back to box "roll back to v1", with a green check

Badges 1, 2, 3 on the right panel's steps, top to bottom. No badges on the left panel.
```
