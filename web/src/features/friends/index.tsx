import type { Feature } from "../../core/registry";
import { initFriends, followToken } from "./store";
import { FriendsLayer } from "./FriendsLayer";
import { FriendsRail } from "./FriendsRail";
import { FriendsSheet } from "./FriendsSheet";
import { FriendsSettings } from "./FriendsSettings";
import { initFollow, FollowLayer, FollowOverlay } from "./FollowView";
import "./friends.css";

/**
 * Amis & partage : code ami, demandes, position en direct (opt-in), marqueurs sur la carte,
 * « Rejoindre » / « À mi-chemin », partage de trajet par lien `?suivre=`, « bien arrivé ».
 * Panneaux du bas possédés : "friends", "friend", "share", "friends-invite".
 */
export const friends: Feature = {
  id: "friends",
  name: "Amis et partage",
  slots: followToken
    ? [
        { slot: "map", order: 60, Component: FollowLayer },
        { slot: "overlay", order: 10, Component: FollowOverlay },
      ]
    : [
        { slot: "map", order: 60, Component: FriendsLayer },
        { slot: "rail", order: 40, Component: FriendsRail },
        { slot: "sheet", order: 50, Component: FriendsSheet },
        { slot: "settings", order: 60, Component: FriendsSettings },
      ],
  init: () => {
    const a = initFriends();
    const b = initFollow();
    return () => { a(); b(); };
  },
};
