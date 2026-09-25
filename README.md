# Studio MVP installeren

Voor medewerkers van Studio MVP: zet je Mac in één keer klaar. Open Terminal (Cmd + spatiebalk, typ "Terminal",
Enter), plak deze regel en druk op Enter:

```sh
curl -fsSL https://raw.githubusercontent.com/mennovanpaassen/studiomvp-installeer/main/installeer.sh | bash
```

Volg daarna de vragen op het scherm. Je hebt nodig: een Mac waarop je beheerder bent, de GitHub-inlog van het bureau,
een Sanity-account in de organisatie Studio MVP en het Studio MVP-wachtwoord (dat krijg je apart).

Dit script bevat geen wachtwoorden, tokens of sleutels. Het installeert Homebrew, Node en het GitHub-programma, haalt
de (privé) Studio MVP-repo op en start daar de installatie. De bron en de tests staan in de privé-repo
`mennovanpaassen/studiomvp-starter`; dit bestand is daar een kopie van.
