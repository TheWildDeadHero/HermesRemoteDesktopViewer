package com.limelight.hermes;

import android.content.Context;
import android.content.SharedPreferences;

import com.limelight.nvstream.http.NvApp;

import java.util.List;

/**
 * Decides which Apollo/Sunshine "application" represents a computer's desktop.
 *
 * Hermes only ever streams the desktop, so instead of showing an app grid we pick one entry:
 * the user's saved choice for that computer, then an entry named "Desktop", then anything
 * containing "desktop", then the only entry if there is just one. If none of these match,
 * {@link #pick} returns null and the caller asks the user once and saves the answer.
 */
public final class DesktopAppPicker {
    private static final String PREFS = "hermes_desktop_apps";
    private static final String KEY_UUID = "uuid_";
    private static final String KEY_NAME = "name_";

    private DesktopAppPicker() {}

    public static NvApp pick(Context context, String computerUuid, List<NvApp> apps) {
        if (apps == null || apps.isEmpty()) {
            return null;
        }

        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String savedUuid = prefs.getString(KEY_UUID + computerUuid, null);
        String savedName = prefs.getString(KEY_NAME + computerUuid, null);

        if (savedUuid != null && !savedUuid.isEmpty()) {
            for (NvApp app : apps) {
                if (savedUuid.equalsIgnoreCase(app.getAppUUID())) {
                    return app;
                }
            }
        }
        if (savedName != null) {
            for (NvApp app : apps) {
                if (savedName.equals(app.getAppName())) {
                    return app;
                }
            }
        }

        for (NvApp app : apps) {
            if ("desktop".equalsIgnoreCase(trim(app.getAppName()))) {
                return app;
            }
        }
        for (NvApp app : apps) {
            String name = app.getAppName();
            if (name != null && name.toLowerCase().contains("desktop")) {
                return app;
            }
        }

        if (apps.size() == 1) {
            return apps.get(0);
        }
        return null;
    }

    public static void save(Context context, String computerUuid, NvApp app) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_UUID + computerUuid, app.getAppUUID() == null ? "" : app.getAppUUID())
                .putString(KEY_NAME + computerUuid, app.getAppName())
                .apply();
    }

    public static void forget(Context context, String computerUuid) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .remove(KEY_UUID + computerUuid)
                .remove(KEY_NAME + computerUuid)
                .apply();
    }

    private static String trim(String s) {
        return s == null ? "" : s.trim();
    }
}
