# a one-off window from 5 minutes ago to 30 minutes from now, computed when the file
# is signed. windows are local wall-clock times in the site's zone.
tz = "Australia/Sydney"
now = DateTime.now!(tz, Tz.TimeZoneDatabase) |> DateTime.to_naive()
minute = %{NaiveDateTime.truncate(now, :second) | second: 0}

[
  mode: :enforce,
  time_zone: tz,
  tool_ids: ["anydesk", "n_central"],
  one_off_windows: [
    %{
      id: "open-now",
      starts_at: NaiveDateTime.add(minute, -5 * 60),
      ends_at: NaiveDateTime.add(minute, 30 * 60)
    }
  ]
]
