# monitor mode, the pilot setting: nothing is blocked, every would-block is logged.
# the weekly window is tuesday and thursday 18:00-20:00 sydney time.
[
  mode: :monitor,
  time_zone: "Australia/Sydney",
  tool_ids: ["anydesk", "n_central", "screenconnect", "teamviewer"],
  recurring_windows: [
    %{id: "tue-thu-evening", days: [2, 4], starts: ~T[18:00:00], ends: ~T[20:00:00]}
  ]
]
