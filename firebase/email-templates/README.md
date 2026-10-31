# HeyMate verification email

`verify-email.html` and `verify-email.txt` are design templates, not live Firebase configuration. The current managed Firebase sender remains unchanged.

Firebase-managed verification emails do not accept custom HTML bodies. Sending this design requires a trusted server to generate a Firebase Admin SDK verification link and send both HTML and plain-text versions through an approved email provider. No provider has been configured for these templates.

Replace `{{VERIFICATION_URL}}` with the generated Firebase link. HTML-escape the value for the HTML version; use the original link in plain text. Never accept a caller-supplied action URL, expose Admin credentials in the Mac app, or log verification links. Preserve Firebase verification and existing resend rate limits.

The logo uses the current HeyMate website asset. There are no tracking pixels or scripts. Local previews use dummy links only. Verify final delivery in actual mail clients before enabling this template.

The user subsequently chose Google sign-in for signup. Custom mail delivery/Resend setup was abandoned before account creation; these templates are retained only as design artifacts.
