package com.limelight.hermes;

import android.app.Dialog;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.DisplayMetrics;
import android.view.Gravity;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.TextView;
import android.widget.Toast;

import com.google.android.material.button.MaterialButton;
import com.google.android.material.button.MaterialButtonToggleGroup;
import com.google.android.material.chip.Chip;
import com.google.android.material.chip.ChipGroup;
import com.google.android.material.materialswitch.MaterialSwitch;
import com.limelight.Game;
import com.limelight.GameMenu;
import com.limelight.R;
import com.limelight.binding.input.GameInputDevice;
import com.limelight.binding.input.KeyboardTranslator;
import com.limelight.preferences.PreferenceConfiguration;

import java.util.ArrayList;

/**
 * In-session menu modelled on Chrome Remote Desktop's side panel: tap the floating handle (or
 * press Back) and a sheet slides in from the right with keyboard, mouse-mode, special keys,
 * display, clipboard and disconnect controls.
 *
 * Anything not surfaced here is still reachable through "More options", which opens Artemis'
 * original advanced menu, so no upstream feature is lost.
 */
public class SessionPanel implements Game.GameMenuCallbacks {

    /** Indices into R.array.mouse_mode_names. */
    private static final int MODE_TOUCH = 1;
    private static final int MODE_TRACKPAD = 2;

    private static final long FOCUS_POLL_MS = 10;
    private static final short VK_SNAPSHOT = 0x2C;

    private final Game game;
    private final GameMenu legacyMenu;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private Dialog dialog;

    public SessionPanel(Game game) {
        this.game = game;
        this.legacyMenu = new GameMenu(game);
    }

    @Override
    public boolean isMenuOpen() {
        return (dialog != null && dialog.isShowing()) || legacyMenu.isMenuOpen();
    }

    @Override
    public void hideMenu() {
        if (dialog != null) {
            if (dialog.isShowing()) {
                dialog.dismiss();
            }
            dialog = null;
        }
        legacyMenu.hideMenu();
    }

    @Override
    public void showMenu(final GameInputDevice device) {
        if (game.isFinishing()) {
            return;
        }
        if (isMenuOpen()) {
            // Back pressed again while open: behave like CRD and just close it
            hideMenu();
            return;
        }

        dialog = new Dialog(game, R.style.Theme_Hermes_SessionPanel);
        View root = LayoutInflater.from(dialog.getContext()).inflate(R.layout.hermes_session_panel, null);
        dialog.setContentView(root);
        dialog.setCanceledOnTouchOutside(true);

        bindHeader(root);
        bindInputMode(root);
        bindKeys(root);
        bindDisplay(root);
        bindActions(root, device);

        showImmersive(dialog);
    }

    // ---------------------------------------------------------------------------------------

    private void bindHeader(View root) {
        TextView title = root.findViewById(R.id.panelTitle);
        String name = game.getPcName();
        title.setText(name != null ? name : game.getString(R.string.hermes_title));
        root.findViewById(R.id.panelClose).setOnClickListener(v -> hideMenu());
    }

    private void bindInputMode(View root) {
        final MaterialButtonToggleGroup group = root.findViewById(R.id.inputModeGroup);
        final TextView help = root.findViewById(R.id.inputModeHelp);

        if (!game.allowChangeMouseMode) {
            group.setEnabled(false);
            for (int i = 0; i < group.getChildCount(); i++) {
                group.getChildAt(i).setEnabled(false);
            }
        }

        int mode = game.getCurrentMouseMode();
        if (mode == MODE_TOUCH) {
            group.check(R.id.inputTouch);
            help.setText(R.string.hermes_input_touch_help);
        } else if (mode == MODE_TRACKPAD) {
            group.check(R.id.inputTrackpad);
            help.setText(R.string.hermes_input_trackpad_help);
        } else {
            // Some other Artemis mode (multi-touch, gaming trackpad…) is active: show neither
            help.setText(null);
            help.setVisibility(View.GONE);
        }

        group.addOnButtonCheckedListener((g, checkedId, isChecked) -> {
            if (!isChecked) {
                return;
            }
            if (checkedId == R.id.inputTouch && game.getCurrentMouseMode() != MODE_TOUCH) {
                game.setMouseModeAndRemember(MODE_TOUCH);
                help.setVisibility(View.VISIBLE);
                help.setText(R.string.hermes_input_touch_help);
            } else if (checkedId == R.id.inputTrackpad && game.getCurrentMouseMode() != MODE_TRACKPAD) {
                game.setMouseModeAndRemember(MODE_TRACKPAD);
                help.setVisibility(View.VISIBLE);
                help.setText(R.string.hermes_input_trackpad_help);
            }
        });
    }

    private void bindKeys(View root) {
        ChipGroup keys = root.findViewById(R.id.keysGroup);
        addKeyChip(keys, R.string.hermes_key_task_manager,
                KeyboardTranslator.VK_LCONTROL, KeyboardTranslator.VK_LSHIFT, KeyboardTranslator.VK_ESCAPE);
        addKeyChip(keys, R.string.hermes_key_win, KeyboardTranslator.VK_LWIN);
        addKeyChip(keys, R.string.hermes_key_alt_tab, KeyboardTranslator.VK_LMENU, KeyboardTranslator.VK_TAB);
        addKeyChip(keys, R.string.hermes_key_esc, KeyboardTranslator.VK_ESCAPE);
        addKeyChip(keys, R.string.hermes_key_show_desktop, KeyboardTranslator.VK_LWIN, KeyboardTranslator.VK_D);
        addKeyChip(keys, R.string.hermes_key_print_screen, VK_SNAPSHOT);

        Chip more = newChip(keys, R.string.hermes_key_more);
        more.setOnClickListener(v -> {
            hideMenu();
            legacyMenu.showSpecialKeysMenu();
        });
        keys.addView(more);
    }

    private void addKeyChip(ChipGroup group, int labelRes, int... keyCodes) {
        final short[] codes = new short[keyCodes.length];
        for (int i = 0; i < keyCodes.length; i++) {
            codes[i] = (short) keyCodes[i];
        }
        Chip chip = newChip(group, labelRes);
        chip.setOnClickListener(v -> dismissThenWithFocus(() -> game.sendKeys(codes)));
        group.addView(chip);
    }

    private Chip newChip(ChipGroup group, int labelRes) {
        Chip chip = new Chip(group.getContext());
        chip.setText(labelRes);
        chip.setCheckable(false);
        return chip;
    }

    private void bindDisplay(View root) {
        MaterialButtonToggleGroup scale = root.findViewById(R.id.scaleGroup);
        PreferenceConfiguration.ScaleMode current = game.getVideoScaleMode();
        if (current == PreferenceConfiguration.ScaleMode.FILL) {
            scale.check(R.id.scaleFill);
        } else if (current == PreferenceConfiguration.ScaleMode.STRETCH) {
            scale.check(R.id.scaleStretch);
        } else {
            scale.check(R.id.scaleFit);
        }
        scale.addOnButtonCheckedListener((g, checkedId, isChecked) -> {
            if (!isChecked) {
                return;
            }
            if (checkedId == R.id.scaleFill) {
                game.setVideoScaleMode(PreferenceConfiguration.ScaleMode.FILL);
            } else if (checkedId == R.id.scaleStretch) {
                game.setVideoScaleMode(PreferenceConfiguration.ScaleMode.STRETCH);
            } else {
                game.setVideoScaleMode(PreferenceConfiguration.ScaleMode.FIT);
            }
        });

        MaterialSwitch zoom = root.findViewById(R.id.switchZoom);
        zoom.setChecked(game.isZoomModeEnabled());
        zoom.setOnCheckedChangeListener((b, checked) -> {
            if (checked != game.isZoomModeEnabled()) {
                game.toggleZoomMode();
            }
        });

        MaterialSwitch stats = root.findViewById(R.id.switchStats);
        stats.setChecked(game.isPerfOverlayEnabled());
        stats.setOnCheckedChangeListener((b, checked) -> {
            if (checked != game.isPerfOverlayEnabled()) {
                game.toggleHUD();
            }
        });

        MaterialButton rotate = root.findViewById(R.id.actionRotate);
        if (game.isOnExternalDisplay()) {
            rotate.setVisibility(View.GONE);
        }
        rotate.setOnClickListener(v -> dismissThenWithFocus(game::rotateScreen));
    }

    private void bindActions(View root, final GameInputDevice device) {
        root.findViewById(R.id.actionKeyboard).setOnClickListener(
                v -> dismissThenWithFocus(game::toggleKeyboard));

        root.findViewById(R.id.actionClipboardSend).setOnClickListener(
                v -> dismissThenWithFocus(() -> game.sendClipboard(true)));
        root.findViewById(R.id.actionClipboardGet).setOnClickListener(
                v -> dismissThenWithFocus(() -> game.getClipboard(0)));

        View serverCommands = root.findViewById(R.id.actionServerCommands);
        final ArrayList<String> cmds = game.getServerCmds();
        if (cmds == null || cmds.isEmpty()) {
            serverCommands.setVisibility(View.GONE);
        } else {
            serverCommands.setOnClickListener(v -> {
                hideMenu();
                legacyMenu.showServerCmd(cmds);
            });
        }

        root.findViewById(R.id.actionMore).setOnClickListener(v -> {
            hideMenu();
            legacyMenu.showAdvancedMenu(device);
        });

        root.findViewById(R.id.actionDisconnect).setOnClickListener(v -> {
            hideMenu();
            game.disconnect();
        });
        root.findViewById(R.id.actionEndSession).setOnClickListener(v -> {
            hideMenu();
            game.quit();
        });
    }

    // ---------------------------------------------------------------------------------------

    /**
     * Many actions (soft keyboard, clipboard access, key injection) only work once the stream
     * window has input focus again, so close the panel and wait for focus before running them.
     */
    private void dismissThenWithFocus(final Runnable action) {
        hideMenu();
        runWithGameFocus(action, 0);
    }

    private void runWithGameFocus(final Runnable action, final int attempts) {
        if (game.isFinishing()) {
            return;
        }
        // Give up waiting after ~1s and run anyway rather than silently dropping the action
        if (!game.hasWindowFocus() && attempts < 100) {
            handler.postDelayed(() -> runWithGameFocus(action, attempts + 1), FOCUS_POLL_MS);
            return;
        }
        try {
            action.run();
        } catch (RuntimeException e) {
            Toast.makeText(game, e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    /** Shows the sheet docked to the right without kicking the stream out of immersive mode. */
    private void showImmersive(Dialog d) {
        Window window = d.getWindow();
        if (window == null) {
            d.show();
            return;
        }

        DisplayMetrics dm = game.getResources().getDisplayMetrics();
        int maxWidth = (int) (360 * dm.density);
        int width = Math.min(maxWidth, (int) (dm.widthPixels * 0.9f));

        window.setGravity(Gravity.END | Gravity.TOP);
        window.setLayout(width, ViewGroup.LayoutParams.MATCH_PARENT);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            WindowManager.LayoutParams lp = window.getAttributes();
            lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            window.setAttributes(lp);
        }

        // Classic trick: show the dialog unfocusable, copy the activity's system UI flags,
        // then make it focusable so the nav/status bars don't pop back in.
        window.setFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE);
        d.show();
        window.getDecorView().setSystemUiVisibility(
                game.getWindow().getDecorView().getSystemUiVisibility());
        window.clearFlags(WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE);
    }
}
