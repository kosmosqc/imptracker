What it does:


• Enlarges the default Wild Imp count on the Implosion icon to make it easier to read in combat

• Adds a green ready frame to supported cooldowns when they are ready to use

• For Implosion, the frame only turns green when the spell is off cooldown and the addon estimates that you have 6 or more Wild Imps available for an optimal cast

• Adds ready borders to important Demonology cooldowns

• Tracks Call Dreadstalkers, Power Siphon, Grimoire, Summon Demonic Tyrant, and Summon Doomguard

• Adds a Hand of Gul'dan cast counter over the Tyrant icon during your Tyrant setup window

• Includes /wit options with per-icon settings, so you can disable any overlay you do not want



disclaimer : This estimate on implosion is not perfect. Since Midnight blocks direct access to some combat data, ImpTracker has to track Wild Imps locally using safe logic. It also attempts to account for Inner Demons. Based on testing, the result is reliable enough(90%+) to be useful in real gameplay, while still letting you make the final call using the default UI count when needed.

 

Design goals:

    Lightweight
    Clear at a glance
    Built specifically for Demonology
    Local tracking that stays usable in combat
    A practical alternative to WeakAura (rip) for players who want a similar setup

Notes:

    Require enabling the default ui icon for essential cooldown the current supported cd are all included in the below image
    Wild Imp behavior is estimated locally for combat safety
    Cooldown tracking starts after the first successful cast of each tracked spell
    Best suited for players who want compact rotational support without turning their UI into a full aura suite
