// breakline one-pager for msps (D50). render with the pinned typst:
//   cloud/priv/bin/typst compile docs/sales/one-pager.typ docs/sales/breakline-one-pager.pdf
// every claim here is something the product does today; keep it in step with the landing
// page (cloud/lib/cloud_web/controllers/page_html/home.html.heex)

#let teal = rgb("#0b7c8c")
#let ink = rgb("#0f1a1f")
#let muted = rgb("#4d5d65")
#let line-c = rgb("#d5dee2")
#let soft = rgb("#eef6f7")

#set document(title: "Breakline: a lock outside your RMM", author: "Breakline")
#set page(paper: "a4", margin: (x: 16mm, top: 13mm, bottom: 12mm))
#set text(font: ("Noto Sans", "DejaVu Sans"), size: 9.4pt, fill: ink, lang: "en", region: "au")
#set par(leading: 0.62em, justify: false)

#let label(t) = text(size: 7.5pt, weight: 600, fill: teal, tracking: 0.12em, upper(t))
#let h(t) = block(above: 12pt, below: 5pt, text(size: 11.5pt, weight: 700, t))

#grid(
  columns: (1fr, auto),
  align: (left + bottom, right + bottom),
  label[Breakline · for Australian MSPs], text(size: 8pt, fill: muted)[November 2026],
)
#v(4pt)
#text(size: 27pt, weight: 800, tracking: -0.01em)[A lock outside your RMM.]
#v(2pt)
#block(width: 94%, text(size: 10.8pt, fill: muted)[
  When an RMM is compromised, every control inside it goes too: consent prompts, allowlists,
  your own admin settings. Breakline sits at each client site, outside your RMM, and shuts
  remote access at every site the moment your tool is listed as exploited. Only a passkey
  reopens it.
])

#v(8pt)
#block(width: 100%, fill: soft, radius: 6pt, inset: (x: 12pt, y: 10pt))[
  #label[Why outside] \
  In August 2026 the ACSC warned that N-able N-central was being exploited in Australia.
  Attackers used the RMM's own remote-control feature to reach client machines, then set up
  tunnels to keep their access. Breakline takes its orders only from policies signed in its
  own cloud, so someone holding your RMM console can't open it.
]

#v(6pt)
#grid(
  columns: (1fr, 1fr, 1fr),
  column-gutter: 14pt,
  [
    #h[Emergency lockdown]
    Breakline checks CISA's exploited-vulnerabilities list every 30 minutes. When your tool
    appears, remote access closes at every client site that uses it, even if your RMM console
    is in someone else's hands. Once you've patched, a passkey reopens it.
  ],
  [
    #h[Windows and approvals, if wanted]
    For remote-control tools such as AnyDesk, TeamViewer or ScreenConnect, a client can ask
    that sessions open only in a booked window or after a passkey approval. A lock cuts live
    sessions on the spot.
  ],
  [
    #h[Proof for clients and insurers]
    Every open, close, approval and lockdown goes into a tamper-evident log. Export it as a
    PDF that can be checked offline.
  ],
)

#v(12pt)
#line(length: 100%, stroke: 0.6pt + line-c)
#v(8pt)
#grid(
  columns: (1.15fr, 1fr),
  column-gutter: 18pt,
  [
    #h[A free pilot, monitor mode first]
    #set enum(numbering: n => text(fill: teal, weight: 700)[#n.], spacing: 6pt)
    + Install the Breakline package on a small Linux box or VM at one client site, or at your
      own office. DNS-only mode needs no rewiring.
    + Enrol it from the dashboard with a one-time code.
    + For a few weeks it blocks nothing. It records when your RMM and remote tools reach the
      site, so you see your own traffic before anything changes.
    + Then you decide, client by client, whether to enforce.

    #v(2pt)
    *The first five sites are free during a pilot.*
  ],
  [
    #h[How it works]
    #set list(marker: text(fill: teal)[•], spacing: 6pt)
    - A gateway at the site answers DNS and holds firewall rules for the remote-access tools
      in its catalogue (N-central and Take Control, ScreenConnect, NinjaOne, Datto RMM,
      AnyDesk, TeamViewer, Splashtop).
    - It only accepts policies signed by the Breakline cloud, and keeps enforcing the last
      one if the cloud is unreachable.
    - It fails closed: no policy, or a clock it can't trust, means locked.

    #h[What it doesn't do]
    It closes the door your RMM uses. It doesn't replace your endpoint protection, and it
    can't remove an attacker who is already inside a network.
  ],
)

#v(10pt)
#let shot(path, caption) = stack(
  spacing: 5pt,
  box(stroke: 0.6pt + line-c, radius: 4pt, clip: true, image(path, height: 38mm)),
  text(size: 8.5pt, fill: muted, caption),
)
#grid(
  columns: (1fr, 1fr),
  column-gutter: 14pt,
  shot("img/demo-locked.png")[Locked: the clinic PC can't reach AnyDesk; the web works.],
  shot("img/demo-open.png")[Open for 15 minutes, approved with a passkey.],
)

#v(1fr)
#text(size: 8pt, fill: muted)[
  Breakline · built in Australia · screens are from a real run of the cloud, a gateway box and
  a clinic PC; a one-minute video of it comes with this page
]
