# Validate streaming handoff on Apple TV

## Run one title link

1. Follow the repository’s build setup. In Xcode, select the SpelunkrTV scheme, your signing team and a physical Apple TV running tvOS 27.
2. In **Edit Scheme → Run**, select the **Debug** build configuration. Under **Arguments → Arguments Passed On Launch**, add two enabled entries for `--probe-streaming-link <URL>`. Put `--probe-streaming-link` in the first entry and the full provider title URL in the second. Use a public link without account identifiers or tokens.
3. Run the app. On the **Streaming handoff test** screen, select **Open link** with the remote. HTTPS requests use universal-link-only mode. Provider-supplied custom schemes use the normal system open behavior. Test each candidate URL separately. Filter the Xcode console for `streaming-handoff` to find the system open result.
4. Record the system open result and what the TV displayed. Identify the foreground app, landing screen, displayed title and whether playback started automatically, started after selecting Play, or was unavailable. Return to SpelunkrTV and check that the probe is available for another attempt. Disable both arguments to run the guide.

## Device test matrix

Each result cell is a separate physical-device run. The links below are official US title pages to try as universal links. Their tvOS routing is unverified. If one fails, repeat with a provider-supplied or licensed tvOS link when available. Use titles available to the test account in its region.

| Provider | Content | Installed and signed in | Installed and signed out | App missing |
| --- | --- | --- | --- | --- |
| Netflix | Movie, [Glass Onion](https://www.netflix.com/title/81458416) | Exact movie and playback | Sign-in flow and movie after sign-in | Record open result and screen |
| Netflix | Series, [Stranger Things](https://www.netflix.com/title/80057281) | Exact series and episode reached | Sign-in flow and series after sign-in | Record open result and screen |
| Disney+ | Movie, [Moana](https://www.disneyplus.com/browse/entity-e8896bfa-1052-41f7-ae2e-00255d77cf05) | Exact movie and playback | Sign-in flow and movie after sign-in | Record open result and screen |
| Disney+ | Series, [The Mandalorian](https://www.disneyplus.com/browse/entity-422f6dcc-226f-44e7-98d4-22de69b31cf3) | Exact series and episode reached | Sign-in flow and series after sign-in | Record open result and screen |
| HBO Max | Movie, [Barbie](https://www.hbomax.com/movie/80bc4915-c826-499f-9961-b422b17559b6) | Exact movie and playback | Sign-in flow and movie after sign-in | Record open result and screen |
| HBO Max | Series, [The Last of Us](https://www.hbomax.com/show/93ba22b1-833e-47ba-ae94-8ee7b9eefa9a) | Exact series and episode reached | Sign-in flow and series after sign-in | Record open result and screen |

A successful system open means tvOS accepted the request. Confirm title routing visually. Record a provider home page, profile picker, another app, wrong title or playback restriction as the observed outcome. For series links, distinguish a series page from a particular episode and record which episode played. If sign-in interrupts the handoff, check whether the intended title appears after sign-in. With the app missing, an HTTPS link without an eligible installed handler should be rejected. Record any other observed destination.

For each run, capture the date, Apple TV model, tvOS and provider app versions, region, app/account state, public title URL, expected title, system result, visible destination, playback and return behavior. Keep credentials, account details and sign-in codes out of notes and screenshots.

A provider qualifies for guide listings once both its movie and series links reach the correct title in the installed, signed-in app.
