package com.limelight.hermes;

import android.app.ActivityManager;
import android.app.Service;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;
import android.net.Uri;
import android.opengl.GLSurfaceView;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.text.InputFilter;
import android.text.InputType;
import android.view.LayoutInflater;
import android.view.Menu;
import android.view.View;
import android.widget.EditText;
import android.widget.Toast;

import androidx.appcompat.app.AlertDialog;
import androidx.appcompat.app.AppCompatActivity;
import androidx.appcompat.widget.PopupMenu;
import androidx.preference.PreferenceManager;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import com.google.android.material.appbar.MaterialToolbar;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import com.google.android.material.floatingactionbutton.ExtendedFloatingActionButton;
import com.google.android.material.textfield.TextInputLayout;
import com.limelight.AppView;
import com.limelight.LimeLog;
import com.limelight.ProfilesActivity;
import com.limelight.R;
import com.limelight.binding.PlatformBinding;
import com.limelight.binding.crypto.AndroidCryptoProvider;
import com.limelight.computers.ComputerManagerListener;
import com.limelight.computers.ComputerManagerService;
import com.limelight.grid.assets.DiskAssetLoader;
import com.limelight.nvstream.http.ComputerDetails;
import com.limelight.nvstream.http.NvApp;
import com.limelight.nvstream.http.NvHTTP;
import com.limelight.nvstream.http.PairingManager;
import com.limelight.nvstream.http.PairingManager.PairState;
import com.limelight.nvstream.jni.MoonBridge;
import com.limelight.nvstream.wol.WakeOnLanSender;
import com.limelight.preferences.GlPreferences;
import com.limelight.preferences.PreferenceConfiguration;
import com.limelight.preferences.StreamSettings;
import com.limelight.utils.Dialog;
import com.limelight.utils.HelpLauncher;
import com.limelight.utils.ServerHelper;
import com.limelight.utils.ShortcutHelper;
import com.limelight.utils.SpinnerDialog;
import com.limelight.utils.UiHelper;

import org.xmlpull.v1.XmlPullParserException;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.StringReader;
import java.net.UnknownHostException;
import java.util.List;

import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

/**
 * Hermes' home screen: a Chrome Remote Desktop-style list of computers.
 *
 * Unlike Moonlight/Artemis there is no per-computer app grid. Tapping a paired, online computer
 * goes straight into its desktop (on an Apollo virtual display when the host supports it).
 * Discovery, polling, pairing and Wake-on-LAN reuse Artemis' ComputerManagerService.
 */
public class ComputerListActivity extends AppCompatActivity implements ComputerListAdapter.Listener {

    /** Optional extra: UUID of a computer to connect to as soon as it is seen online. */
    public static final String EXTRA_CONNECT_UUID = "hermes_connect_uuid";

    private ComputerManagerService.ComputerManagerBinder managerBinder;
    private boolean freezeUpdates, runningPolling, inForeground, uiReady;
    private ComputerListAdapter adapter;
    private View emptyState;
    private ShortcutHelper shortcutHelper;

    private static final long WAKE_CONNECT_TIMEOUT_MS = 3 * 60 * 1000;

    private volatile String pendingConnectUuid;
    // After Wake-on-LAN: connect when the computer comes online, ignoring OFFLINE reports
    // while it boots, until the deadline passes.
    private volatile String wakeConnectUuid;
    private volatile long wakeConnectDeadline;
    private ComputerDetails.AddressTuple pendingPairingAddress;
    private String pendingPairingPin, pendingPairingPassphrase;
    private boolean connectInProgress;

    private final ServiceConnection serviceConnection = new ServiceConnection() {
        public void onServiceConnected(ComponentName className, IBinder binder) {
            final ComputerManagerService.ComputerManagerBinder localBinder =
                    (ComputerManagerService.ComputerManagerBinder) binder;
            new Thread(() -> {
                localBinder.waitForReady();
                managerBinder = localBinder;
                startComputerUpdates();
                // Generate our client keypair early so discovery/pairing isn't delayed later
                new AndroidCryptoProvider(ComputerListActivity.this).getClientCertificate();
            }).start();
        }

        public void onServiceDisconnected(ComponentName className) {
            managerBinder = null;
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        inForeground = true;

        readIntentExtras(getIntent());

        // Artemis' decoder selection relies on knowing the GL renderer. Fetch it once per
        // OS build (exactly like PcView) before showing the real UI.
        final GlPreferences glPrefs = GlPreferences.readPreferences(this);
        if (!glPrefs.savedFingerprint.equals(Build.FINGERPRINT) || glPrefs.glRenderer.isEmpty()) {
            GLSurfaceView surfaceView = new GLSurfaceView(this);
            surfaceView.setRenderer(new GLSurfaceView.Renderer() {
                @Override
                public void onSurfaceCreated(GL10 gl10, EGLConfig eglConfig) {
                    glPrefs.glRenderer = gl10.glGetString(GL10.GL_RENDERER);
                    glPrefs.savedFingerprint = Build.FINGERPRINT;
                    glPrefs.writePreferences();
                    LimeLog.info("Fetched GL Renderer: " + glPrefs.glRenderer);
                    runOnUiThread(() -> completeOnCreate());
                }

                @Override
                public void onSurfaceChanged(GL10 gl10, int i, int i1) {
                }

                @Override
                public void onDrawFrame(GL10 gl10) {
                }
            });
            setContentView(surfaceView);
        } else {
            completeOnCreate();
        }
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        readIntentExtras(intent);
    }

    private void readIntentExtras(Intent intent) {
        if (intent == null) {
            return;
        }
        String connectUuid = intent.getStringExtra(EXTRA_CONNECT_UUID);
        if (connectUuid != null) {
            pendingConnectUuid = connectUuid;
        }

        // Deep-link pairing handed over from AddComputerManually (art:// URIs with a PIN)
        String hostname = intent.getStringExtra("hostname");
        int port = intent.getIntExtra("port", NvHTTP.DEFAULT_HTTP_PORT);
        if (port <= 0) {
            port = NvHTTP.DEFAULT_HTTP_PORT;
        }
        String pin = intent.getStringExtra("pin");
        String passphrase = intent.getStringExtra("passphrase");
        if (hostname != null && pin != null && passphrase != null) {
            pendingPairingAddress = new ComputerDetails.AddressTuple(hostname, port);
            pendingPairingPin = pin;
            pendingPairingPassphrase = passphrase;
        }
    }

    private void completeOnCreate() {
        if (uiReady) {
            return;
        }
        uiReady = true;

        shortcutHelper = new ShortcutHelper(this);
        UiHelper.setLocale(this);
        PreferenceManager.setDefaultValues(this, R.xml.preferences, false);

        setContentView(R.layout.activity_computer_list);
        UiHelper.notifyNewRootView(this);

        MaterialToolbar toolbar = findViewById(R.id.toolbar);
        toolbar.setOnMenuItemClickListener(item -> {
            int id = item.getItemId();
            if (id == R.id.action_settings) {
                startActivity(new Intent(this, StreamSettings.class));
                return true;
            } else if (id == R.id.action_profiles) {
                startActivity(new Intent(this, ProfilesActivity.class));
                return true;
            } else if (id == R.id.action_help) {
                HelpLauncher.launchSetupGuide(this);
                return true;
            }
            return false;
        });

        adapter = new ComputerListAdapter(this);
        RecyclerView list = findViewById(R.id.computerList);
        list.setLayoutManager(new LinearLayoutManager(this));
        list.setAdapter(adapter);
        list.setItemAnimator(null); // status updates arrive constantly; avoid flicker

        emptyState = findViewById(R.id.emptyState);
        updateEmptyState();

        ExtendedFloatingActionButton fab = findViewById(R.id.addComputerFab);
        fab.setOnClickListener(v -> showAddComputerDialog());
        list.addOnScrollListener(new RecyclerView.OnScrollListener() {
            @Override
            public void onScrolled(RecyclerView recyclerView, int dx, int dy) {
                if (dy > 8) {
                    fab.shrink();
                } else if (dy < -8) {
                    fab.extend();
                }
            }
        });

        bindService(new Intent(this, ComputerManagerService.class), serviceConnection,
                Service.BIND_AUTO_CREATE);
    }

    private void updateEmptyState() {
        if (emptyState != null && adapter != null) {
            emptyState.setVisibility(adapter.getComputerCount() == 0 ? View.VISIBLE : View.GONE);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Polling
    // ---------------------------------------------------------------------------------------

    private void startComputerUpdates() {
        if (managerBinder != null && !runningPolling && inForeground) {
            freezeUpdates = false;
            managerBinder.startPolling(new ComputerManagerListener() {
                @Override
                public void notifyComputerUpdated(final ComputerDetails details) {
                    if (freezeUpdates) {
                        return;
                    }
                    runOnUiThread(() -> onComputerUpdated(details));

                    if (details.pairState == PairState.PAIRED) {
                        shortcutHelper.createAppViewShortcutForOnlineHost(details);
                    }
                }
            });
            runningPolling = true;
        }
    }

    private void stopComputerUpdates(boolean wait) {
        if (managerBinder != null && runningPolling) {
            freezeUpdates = true;
            managerBinder.stopPolling();
            if (wait) {
                managerBinder.waitForPollingStopped();
            }
            runningPolling = false;
        }
    }

    private void onComputerUpdated(ComputerDetails details) {
        if (adapter == null || isGone()) {
            return;
        }
        adapter.upsert(details);
        updateEmptyState();

        boolean online = details.state == ComputerDetails.State.ONLINE;

        if (pendingPairingAddress != null && online && pendingPairingAddress.equals(details.activeAddress)) {
            String pin = pendingPairingPin, passphrase = pendingPairingPassphrase;
            pendingPairingAddress = null;
            pendingPairingPin = null;
            pendingPairingPassphrase = null;
            doPair(details, pin, passphrase);
            return;
        }

        if (wakeConnectUuid != null && wakeConnectUuid.equals(details.uuid)) {
            if (online && details.activeAddress != null) {
                wakeConnectUuid = null;
                onComputerClicked(details);
            } else if (System.currentTimeMillis() > wakeConnectDeadline) {
                wakeConnectUuid = null;
            }
            return;
        }

        if (pendingConnectUuid != null && pendingConnectUuid.equals(details.uuid)
                && details.state != ComputerDetails.State.UNKNOWN) {
            pendingConnectUuid = null;
            onComputerClicked(details);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        UiHelper.showDecoderCrashDialog(this);
        inForeground = true;
        connectInProgress = false;
        startComputerUpdates();
    }

    @Override
    protected void onPause() {
        super.onPause();
        inForeground = false;
        stopComputerUpdates(false);
    }

    @Override
    protected void onStop() {
        super.onStop();
        Dialog.closeDialogs();
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (managerBinder != null) {
            unbindService(serviceConnection);
        }
    }

    /** True once this instance can no longer show UI (finishing or destroyed by recreation). */
    private boolean isGone() {
        return isFinishing() || (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1 && isDestroyed());
    }

    /**
     * The adapter can hold a stale snapshot (e.g. from discovery) without the pinned server
     * certificate; always act on the service's live copy when there is one.
     */
    private ComputerDetails live(ComputerDetails computer) {
        if (managerBinder != null && computer != null && computer.uuid != null) {
            ComputerDetails l = managerBinder.getComputer(computer.uuid);
            if (l != null) {
                return l;
            }
        }
        return computer;
    }

    private boolean ensureManager() {
        if (managerBinder == null) {
            Toast.makeText(this, R.string.error_manager_not_running, Toast.LENGTH_LONG).show();
            return false;
        }
        return true;
    }

    // ---------------------------------------------------------------------------------------
    // List interactions
    // ---------------------------------------------------------------------------------------

    @Override
    public void onComputerClicked(ComputerDetails computer) {
        if (computer.state == ComputerDetails.State.UNKNOWN) {
            Toast.makeText(this, R.string.hermes_status_checking, Toast.LENGTH_SHORT).show();
        } else if (computer.state == ComputerDetails.State.OFFLINE || computer.activeAddress == null) {
            showOfflineDialog(computer);
        } else if (computer.pairState != PairState.PAIRED) {
            showPairChooser(computer);
        } else {
            connectToDesktop(computer, false);
        }
    }

    @Override
    public void onComputerMenu(final ComputerDetails computer, View anchor) {
        final int CONNECT = 1, PAIR = 2, WAKE = 3, END = 4, CHOOSE = 5, WEB = 6, NETTEST = 7,
                DETAILS = 8, UNPAIR = 9, REMOVE = 10;

        PopupMenu popup = new PopupMenu(this, anchor);
        Menu menu = popup.getMenu();
        boolean online = computer.state == ComputerDetails.State.ONLINE && computer.activeAddress != null;
        boolean paired = computer.pairState == PairState.PAIRED;

        if (online && paired) {
            menu.add(Menu.NONE, CONNECT, 0, R.string.hermes_menu_connect);
            if (computer.runningGameId != 0) {
                menu.add(Menu.NONE, END, 1, R.string.hermes_menu_end_session);
            }
            menu.add(Menu.NONE, CHOOSE, 2, R.string.hermes_menu_choose_desktop);
        }
        if (online && !paired) {
            menu.add(Menu.NONE, PAIR, 0, R.string.hermes_menu_pair);
        }
        if (!online && computer.macAddress != null) {
            menu.add(Menu.NONE, WAKE, 0, R.string.hermes_menu_wake);
        }
        if (online && !computer.nvidiaServer) {
            menu.add(Menu.NONE, WEB, 3, R.string.hermes_menu_web_ui);
        }
        menu.add(Menu.NONE, NETTEST, 4, R.string.hermes_menu_test_network);
        menu.add(Menu.NONE, DETAILS, 5, R.string.hermes_menu_details);
        if (online && paired) {
            menu.add(Menu.NONE, UNPAIR, 6, R.string.hermes_menu_unpair);
        }
        menu.add(Menu.NONE, REMOVE, 7, R.string.hermes_menu_remove);

        popup.setOnMenuItemClickListener(item -> {
            switch (item.getItemId()) {
                case CONNECT:
                    connectToDesktop(computer, false);
                    return true;
                case PAIR:
                    showPairChooser(computer);
                    return true;
                case WAKE:
                    doWakeOnLan(computer);
                    return true;
                case END:
                    confirmEndSession(computer);
                    return true;
                case CHOOSE:
                    connectToDesktop(computer, true);
                    return true;
                case WEB: {
                    String url = guessManagementUrl(computer);
                    if (url == null) {
                        Toast.makeText(this, R.string.pcview_error_no_management_url, Toast.LENGTH_LONG).show();
                    } else {
                        HelpLauncher.launchUrl(this, url);
                    }
                    return true;
                }
                case NETTEST:
                    ServerHelper.doNetworkTest(this);
                    return true;
                case DETAILS:
                    Dialog.displayDialog(this, getString(R.string.title_details), computer.toString(), false);
                    return true;
                case UNPAIR:
                    doUnpair(computer);
                    return true;
                case REMOVE:
                    if (ActivityManager.isUserAMonkey()) {
                        return true;
                    }
                    UiHelper.displayDeletePcConfirmationDialog(this, computer, () -> removeComputer(computer), null);
                    return true;
                default:
                    return false;
            }
        });
        popup.show();
    }

    private static String guessManagementUrl(ComputerDetails details) {
        if (details.activeAddress == null) {
            return null;
        }
        return "https://" + details.activeAddress.address + ":" + (details.guessExternalPort() + 1);
    }

    // ---------------------------------------------------------------------------------------
    // Connect straight to the desktop
    // ---------------------------------------------------------------------------------------

    /**
     * Resolves which host entry is the desktop and launches the stream.
     *
     * @param forceChoose show the picker even if a desktop entry can be found automatically
     */
    private void connectToDesktop(ComputerDetails target, final boolean forceChoose) {
        if (!ensureManager() || connectInProgress) {
            return;
        }
        final ComputerDetails computer = live(target);

        // Reconnect to a session that's already running instead of starting a new one,
        // just like CRD reattaches to the existing desktop.
        if (computer.runningGameId != 0 && !forceChoose) {
            launch(computer, new NvApp("Desktop", computer.runningGameUUID, computer.runningGameId, false));
            return;
        }

        connectInProgress = true;
        final SpinnerDialog spinner = SpinnerDialog.displayDialog(this,
                getString(R.string.hermes_connecting_title, computer.name),
                getString(R.string.hermes_connecting_msg), false);

        new Thread(() -> {
            List<NvApp> apps = null;
            String error = null;

            if (!forceChoose && computer.rawAppList != null && !computer.rawAppList.isEmpty()) {
                try {
                    apps = NvHTTP.getAppListByReader(new StringReader(computer.rawAppList));
                } catch (XmlPullParserException | IOException | RuntimeException e) {
                    apps = null;
                }
            }

            if (apps == null || apps.isEmpty()) {
                try {
                    NvHTTP http = new NvHTTP(ServerHelper.getCurrentAddressFromComputer(computer),
                            computer.httpsPort, managerBinder.getUniqueId(), computer.serverCert,
                            PlatformBinding.getCryptoProvider(ComputerListActivity.this));
                    apps = http.getAppList();
                } catch (UnknownHostException e) {
                    error = getString(R.string.error_unknown_host);
                } catch (FileNotFoundException e) {
                    error = getString(R.string.error_404);
                } catch (XmlPullParserException | IOException e) {
                    error = e.getMessage();
                } catch (RuntimeException e) {
                    // e.g. OkHttp rejecting a host name it can't canonicalize
                    error = e.toString();
                }
            }

            final List<NvApp> finalApps = apps;
            final String finalError = error;
            runOnUiThread(() -> {
                spinner.dismiss();
                connectInProgress = false;
                if (isGone() || !inForeground) {
                    // User left while we were loading; don't pop a stream over whatever they're doing
                    return;
                }

                if (finalError != null) {
                    Dialog.displayDialog(this, getString(R.string.conn_error_title), finalError, false);
                    return;
                }
                if (finalApps == null || finalApps.isEmpty()) {
                    Dialog.displayDialog(this, getString(R.string.conn_error_title), getString(R.string.hermes_no_apps), false);
                    return;
                }

                NvApp desktop = forceChoose ? null : DesktopAppPicker.pick(this, computer.uuid, finalApps);
                if (desktop != null) {
                    launch(computer, desktop);
                } else {
                    showDesktopChooser(computer, finalApps, !forceChoose);
                }
            });
        }).start();
    }

    private void showDesktopChooser(final ComputerDetails computer, final List<NvApp> apps, final boolean launchAfter) {
        String[] names = new String[apps.size()];
        for (int i = 0; i < apps.size(); i++) {
            names[i] = apps.get(i).getAppName();
        }

        MaterialAlertDialogBuilder builder = new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.hermes_choose_desktop_title)
                .setItems(names, (dialog, which) -> {
                    NvApp chosen = apps.get(which);
                    DesktopAppPicker.save(this, computer.uuid, chosen);
                    if (launchAfter) {
                        launch(computer, chosen);
                    }
                })
                .setNegativeButton(android.R.string.cancel, null);
        if (launchAfter) {
            // We only get here when nothing obviously named "Desktop" exists
            builder.setTitle(getString(R.string.hermes_choose_desktop_title));
            Toast.makeText(this, R.string.hermes_choose_desktop_msg, Toast.LENGTH_LONG).show();
        }
        builder.show();
    }

    private void launch(ComputerDetails computer, NvApp app) {
        if (!ensureManager() || isGone()) {
            return;
        }
        // Use the binder's live copy so we have the pinned server certificate after pairing
        computer = live(computer);

        boolean wantVDisplay = PreferenceConfiguration.readPreferences(this).useVirtualDisplay;
        boolean vDisplay = wantVDisplay && computer.vDisplaySupported && computer.vDisplayDriverReady;
        if (wantVDisplay && !vDisplay && computer.runningGameId == 0) {
            Toast.makeText(this, getString(R.string.hermes_no_vdisplay, computer.name), Toast.LENGTH_LONG).show();
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ServerHelper.doStart(this, app, computer, managerBinder, vDisplay);
        } else {
            if (computer.state == ComputerDetails.State.OFFLINE || computer.activeAddress == null) {
                Toast.makeText(this, R.string.pair_pc_offline, Toast.LENGTH_SHORT).show();
                return;
            }
            startActivity(ServerHelper.createStartIntent(this, app, computer, managerBinder, vDisplay));
        }
    }

    private void confirmEndSession(final ComputerDetails computer) {
        new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.hermes_end_session_title)
                .setMessage(R.string.hermes_end_session_msg)
                .setPositiveButton(R.string.hermes_end_session, (d, w) -> {
                    if (ensureManager()) {
                        ServerHelper.doQuit(this, live(computer), new NvApp("Desktop", null, 0, false), managerBinder,
                                () -> {
                                    if (managerBinder != null) {
                                        managerBinder.invalidateStateForComputer(computer.uuid);
                                    }
                                });
                    }
                })
                .setNegativeButton(android.R.string.cancel, null)
                .show();
    }

    // ---------------------------------------------------------------------------------------
    // Offline / Wake-on-LAN
    // ---------------------------------------------------------------------------------------

    private void showOfflineDialog(final ComputerDetails computer) {
        MaterialAlertDialogBuilder builder = new MaterialAlertDialogBuilder(this)
                .setTitle(getString(R.string.hermes_offline_title, computer.name));
        if (computer.macAddress != null) {
            builder.setMessage(R.string.hermes_offline_msg)
                    .setPositiveButton(R.string.hermes_wake, (d, w) -> doWakeOnLan(computer))
                    .setNegativeButton(android.R.string.cancel, null);
        } else {
            builder.setMessage(R.string.hermes_offline_no_mac)
                    .setPositiveButton(android.R.string.ok, null);
        }
        builder.show();
    }

    private void doWakeOnLan(final ComputerDetails computer) {
        if (computer.macAddress == null) {
            Toast.makeText(this, R.string.wol_no_mac, Toast.LENGTH_SHORT).show();
            return;
        }
        new Thread(() -> {
            String message;
            try {
                WakeOnLanSender.sendWolPacket(computer);
                message = getString(R.string.wol_waking_msg);
                // Watch for it coming online and connect automatically
                wakeConnectDeadline = System.currentTimeMillis() + WAKE_CONNECT_TIMEOUT_MS;
                wakeConnectUuid = computer.uuid;
                if (managerBinder != null) {
                    managerBinder.invalidateStateForComputer(computer.uuid);
                }
            } catch (IOException e) {
                message = getString(R.string.wol_fail);
            }
            final String toast = message;
            runOnUiThread(() -> Toast.makeText(this, toast, Toast.LENGTH_LONG).show());
        }).start();
    }

    // ---------------------------------------------------------------------------------------
    // Adding computers
    // ---------------------------------------------------------------------------------------

    private void showAddComputerDialog() {
        View view = LayoutInflater.from(this).inflate(R.layout.dialog_hermes_text_input, null);
        TextInputLayout layout = view.findViewById(R.id.firstFieldLayout);
        final EditText hostField = view.findViewById(R.id.firstField);
        layout.setHint(getString(R.string.hermes_add_hint));
        layout.setHelperText(getString(R.string.hermes_add_helper));
        hostField.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);

        final AlertDialog dialog = new MaterialAlertDialogBuilder(this)
                .setTitle(R.string.hermes_add_title)
                .setView(view)
                .setPositiveButton(R.string.hermes_add_button, null)
                .setNegativeButton(android.R.string.cancel, null)
                .create();
        dialog.setOnShowListener(d -> {
            hostField.requestFocus();
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
                String host = hostField.getText().toString().trim();
                if (host.isEmpty()) {
                    layout.setError(getString(R.string.addpc_enter_ip));
                    return;
                }
                dialog.dismiss();
                addComputer(host);
            });
        });
        dialog.show();
    }

    private static Uri parseHostInput(String raw) {
        // Accepts 192.168.1.2, 192.168.1.2:47989, [::1], [::1]:47989 and ::1
        Uri uri = Uri.parse("art://" + raw);
        if (uri.getHost() != null && !uri.getHost().isEmpty()) {
            return uri;
        }
        uri = Uri.parse("art://[" + raw + "]");
        if (uri.getHost() != null && !uri.getHost().isEmpty()) {
            return uri;
        }
        return null;
    }

    private void addComputer(final String rawInput) {
        if (!ensureManager()) {
            return;
        }
        final SpinnerDialog spinner = SpinnerDialog.displayDialog(this,
                getString(R.string.hermes_add_title), getString(R.string.hermes_adding), false);

        new Thread(() -> {
            boolean success = false;
            boolean invalid = false;
            Uri uri = parseHostInput(rawInput);
            try {
                if (uri != null) {
                    int port = uri.getPort() == -1 ? NvHTTP.DEFAULT_HTTP_PORT : uri.getPort();
                    ComputerDetails details = new ComputerDetails();
                    details.manualAddress = new ComputerDetails.AddressTuple(uri.getHost(), port);
                    success = managerBinder.addComputerBlocking(details);
                } else {
                    invalid = true;
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            } catch (IllegalArgumentException e) {
                invalid = true;
            }

            int portTest = MoonBridge.ML_TEST_RESULT_INCONCLUSIVE;
            if (!success && !invalid) {
                portTest = MoonBridge.testClientConnectivity(ServerHelper.CONNECTION_TEST_SERVER, 443,
                        MoonBridge.ML_PORT_FLAG_TCP_47984 | MoonBridge.ML_PORT_FLAG_TCP_47989);
            }

            final boolean ok = success, bad = invalid;
            final int test = portTest;
            runOnUiThread(() -> {
                spinner.dismiss();
                if (isGone()) {
                    return;
                }
                if (ok) {
                    Toast.makeText(this, R.string.addpc_success, Toast.LENGTH_LONG).show();
                } else if (bad) {
                    Dialog.displayDialog(this, getString(R.string.conn_error_title), getString(R.string.addpc_unknown_host), false);
                } else {
                    String text = (test != MoonBridge.ML_TEST_RESULT_INCONCLUSIVE && test != 0)
                            ? getString(R.string.nettest_text_blocked)
                            : getString(R.string.addpc_fail);
                    Dialog.displayDialog(this, getString(R.string.conn_error_title), text, false);
                }
            });
        }).start();
    }

    // ---------------------------------------------------------------------------------------
    // Pairing
    // ---------------------------------------------------------------------------------------

    private void showPairChooser(final ComputerDetails computer) {
        CharSequence[] options = {
                getString(R.string.hermes_pair_otp),
                getString(R.string.hermes_pair_classic)
        };
        new MaterialAlertDialogBuilder(this)
                .setTitle(getString(R.string.hermes_pair_title, computer.name))
                .setItems(options, (d, which) -> {
                    if (which == 0) {
                        showOtpDialog(computer);
                    } else {
                        doPair(computer, null, null);
                    }
                })
                .setNegativeButton(android.R.string.cancel, null)
                .show();
    }

    private void showOtpDialog(final ComputerDetails computer) {
        View view = LayoutInflater.from(this).inflate(R.layout.dialog_hermes_text_input, null);
        final TextInputLayout pinLayout = view.findViewById(R.id.firstFieldLayout);
        final EditText pinField = view.findViewById(R.id.firstField);
        final TextInputLayout passLayout = view.findViewById(R.id.secondFieldLayout);
        final EditText passField = view.findViewById(R.id.secondField);

        pinLayout.setHint(getString(R.string.hermes_pin_hint));
        pinLayout.setHelperText(getString(R.string.hermes_pair_otp_desc));
        pinField.setInputType(InputType.TYPE_CLASS_NUMBER);
        pinField.setFilters(new InputFilter[]{new InputFilter.LengthFilter(4)});
        passLayout.setVisibility(View.VISIBLE);
        passLayout.setHint(getString(R.string.hermes_passphrase_hint));

        final AlertDialog dialog = new MaterialAlertDialogBuilder(this)
                .setTitle(getString(R.string.hermes_pair_title, computer.name))
                .setView(view)
                .setPositiveButton(R.string.hermes_pair_button, null)
                .setNegativeButton(android.R.string.cancel, null)
                .create();
        dialog.setOnShowListener(d -> {
            pinField.requestFocus();
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
                String pin = pinField.getText().toString();
                String passphrase = passField.getText().toString();
                pinLayout.setError(null);
                passLayout.setError(null);
                if (pin.length() != 4) {
                    pinLayout.setError(getString(R.string.pair_pin_length_msg));
                    return;
                }
                if (passphrase.length() < 4) {
                    passLayout.setError(getString(R.string.pair_passphrase_length_msg));
                    return;
                }
                dialog.dismiss();
                doPair(computer, pin, passphrase);
            });
        });
        dialog.show();
    }

    /**
     * Same pairing flow as Artemis' PcView: either we generate a PIN for the user to type into
     * Apollo, or (OTP) the user supplies a PIN + passphrase generated by Apollo.
     * On success we go straight into the desktop.
     */
    private void doPair(ComputerDetails target, final String otp, final String passphrase) {
        final ComputerDetails computer = live(target);
        if (computer.state == ComputerDetails.State.OFFLINE || computer.activeAddress == null) {
            Toast.makeText(this, R.string.pair_pc_offline, Toast.LENGTH_SHORT).show();
            return;
        }
        if (!ensureManager()) {
            return;
        }

        Toast.makeText(this, R.string.pairing, Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            String message;
            boolean success = false;
            try {
                stopComputerUpdates(true);

                NvHTTP httpConn = new NvHTTP(ServerHelper.getCurrentAddressFromComputer(computer),
                        computer.httpsPort, managerBinder.getUniqueId(), computer.serverCert,
                        PlatformBinding.getCryptoProvider(ComputerListActivity.this));
                if (httpConn.getPairState() == PairState.PAIRED) {
                    message = null;
                    success = true;
                } else {
                    String pinStr = otp != null ? otp : PairingManager.generatePinString();

                    if (passphrase == null) {
                        Dialog.displayDialog(this, getString(R.string.pair_pairing_title),
                                getString(R.string.pair_pairing_msg) + " " + pinStr + "\n\n" +
                                        getString(R.string.pair_pairing_help), false);
                    } else {
                        Dialog.displayDialog(this, getString(R.string.pair_pairing_title),
                                getString(R.string.pair_otp_pairing_msg) + "\n\n" +
                                        getString(R.string.pair_otp_pairing_help), false);
                    }

                    PairingManager pm = httpConn.getPairingManager();
                    PairState pairState = pm.pair(httpConn.getServerInfo(true), pinStr, passphrase);
                    if (pairState == PairState.PIN_WRONG) {
                        message = getString(R.string.pair_incorrect_pin);
                    } else if (pairState == PairState.FAILED) {
                        message = computer.runningGameId != 0
                                ? getString(R.string.pair_pc_ingame)
                                : getString(R.string.pair_fail);
                    } else if (pairState == PairState.ALREADY_IN_PROGRESS) {
                        message = getString(R.string.pair_already_in_progress);
                    } else if (pairState == PairState.PAIRED) {
                        message = null;
                        success = true;
                        ComputerDetails live = managerBinder.getComputer(computer.uuid);
                        if (live != null) {
                            live.serverCert = pm.getPairedCert();
                        }
                        managerBinder.invalidateStateForComputer(computer.uuid);
                    } else {
                        message = null;
                    }
                }
            } catch (UnknownHostException e) {
                message = getString(R.string.error_unknown_host);
            } catch (FileNotFoundException e) {
                message = getString(R.string.error_404);
            } catch (XmlPullParserException | IOException e) {
                LimeLog.warning("Pairing failed: " + e);
                message = e.getMessage();
            } catch (RuntimeException e) {
                LimeLog.warning("Pairing failed: " + e);
                message = e.toString();
            }

            Dialog.closeDialogs();

            final String toast = message;
            final boolean ok = success;
            runOnUiThread(() -> {
                if (isGone()) {
                    return;
                }
                if (toast != null) {
                    Toast.makeText(this, toast, Toast.LENGTH_LONG).show();
                }
                startComputerUpdates();
                if (ok && inForeground) {
                    connectToDesktop(computer, false);
                }
            });
        }).start();
    }

    private void doUnpair(ComputerDetails target) {
        final ComputerDetails computer = live(target);
        if (computer.state == ComputerDetails.State.OFFLINE || computer.activeAddress == null) {
            Toast.makeText(this, R.string.error_pc_offline, Toast.LENGTH_SHORT).show();
            return;
        }
        if (!ensureManager()) {
            return;
        }
        Toast.makeText(this, R.string.unpairing, Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            String message;
            try {
                NvHTTP httpConn = new NvHTTP(ServerHelper.getCurrentAddressFromComputer(computer),
                        computer.httpsPort, managerBinder.getUniqueId(), computer.serverCert,
                        PlatformBinding.getCryptoProvider(ComputerListActivity.this));
                if (httpConn.getPairState() == PairState.PAIRED) {
                    httpConn.unpair();
                    message = httpConn.getPairState() == PairState.NOT_PAIRED
                            ? getString(R.string.unpair_success)
                            : getString(R.string.unpair_fail);
                } else {
                    message = getString(R.string.unpair_error);
                }
                managerBinder.invalidateStateForComputer(computer.uuid);
            } catch (UnknownHostException e) {
                message = getString(R.string.error_unknown_host);
            } catch (FileNotFoundException e) {
                message = getString(R.string.error_404);
            } catch (XmlPullParserException | IOException e) {
                message = e.getMessage();
            } catch (RuntimeException e) {
                message = e.toString();
            }
            final String toast = message;
            runOnUiThread(() -> {
                if (!isGone()) {
                    Toast.makeText(this, toast, Toast.LENGTH_LONG).show();
                }
            });
        }).start();
    }

    private void removeComputer(ComputerDetails details) {
        if (!ensureManager()) {
            return;
        }
        managerBinder.removeComputer(details);
        new DiskAssetLoader(this).deleteAssetsForComputer(details.uuid);
        getSharedPreferences(AppView.HIDDEN_APPS_PREF_FILENAME, MODE_PRIVATE)
                .edit()
                .remove(details.uuid)
                .apply();
        DesktopAppPicker.forget(this, details.uuid);
        shortcutHelper.disableComputerShortcut(details, getString(R.string.scut_deleted_pc));
        adapter.remove(details.uuid);
        updateEmptyState();
    }
}
