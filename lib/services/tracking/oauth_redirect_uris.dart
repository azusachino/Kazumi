const defaultBangumiRedirectUri = String.fromEnvironment(
  'BANGUMI_REDIRECT_URI',
  defaultValue: 'kazumi://bangumi-auth',
);
const defaultAniListRedirectUri = String.fromEnvironment(
  'ANILIST_REDIRECT_URI',
  defaultValue: 'kazumi://anilist-auth',
);
