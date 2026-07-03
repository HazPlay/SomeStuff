# SomeStuff

Some scripts I don't mind sharing publicly — no promises on documentation.

Mostly PowerShell stuff from day-to-day M365/Entra ID admin work. Some of it uses the Microsoft Graph module, some uses the Exchange Online module. Nothing here is fancy, and nothing here is guaranteed to work perfectly in your tenant — read before you run, test before you trust.

## ⚠️ Before you use anything here

- These scripts were written for **my** tenant and workflows. Variable names, mappings, and assumptions may need editing for yours.
- Don't just YOLO them into production.
- I'm not responsible if something breaks. Test in a non-prod environment or on a small sample if you can.

## Requirements

Depending on the script, you'll need one or both of:
- [Microsoft Graph PowerShell SDK](https://learn.microsoft.com/powershell/microsoftgraph/installation)
- [Exchange Online Management module](https://learn.microsoft.com/powershell/exchange/exchange-online-powershell)

Check each script's header/comments for the specific scopes or permissions it needs.

## Contributing / Feedback

Not really expecting PRs on a repo called "SomeStuff," but if you spot something broken or dangerous, feel free to open an issue.
