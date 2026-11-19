/**
 * Application-wide settings stored in nc_store
 */
export interface AppSettings {
  /**
   * Open signup is disabled. Only an admin invite link can create an account
   * after the first super admin. The stored value is forced to true.
   * @default true
   */
  invite_only_signup?: boolean;

  /**
   * Prevent non-super users from creating new workspaces
   * @default false
   */
  restrict_workspace_creation?: boolean;
}

/**
 * Default values for app settings
 */
export const DEFAULT_APP_SETTINGS: AppSettings = {
  invite_only_signup: true,
  restrict_workspace_creation: false,
};
