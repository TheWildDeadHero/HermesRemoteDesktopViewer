package com.limelight.hermes;

import android.content.Context;
import android.content.res.ColorStateList;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.TextView;

import androidx.annotation.NonNull;
import androidx.recyclerview.widget.RecyclerView;

import com.limelight.R;
import com.limelight.nvstream.http.ComputerDetails;
import com.limelight.nvstream.http.PairingManager;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/**
 * Chrome Remote Desktop-style list: a section header followed by one card per computer,
 * online computers first, then alphabetical.
 */
public class ComputerListAdapter extends RecyclerView.Adapter<RecyclerView.ViewHolder> {

    public interface Listener {
        void onComputerClicked(ComputerDetails computer);
        void onComputerMenu(ComputerDetails computer, View anchor);
    }

    private static final int TYPE_HEADER = 0;
    private static final int TYPE_COMPUTER = 1;

    private static final int COLOR_ONLINE = 0xFF34A853;
    private static final int COLOR_ATTENTION = 0xFFFBBC04;
    private static final int COLOR_OFFLINE = 0xFF9AA0A6;

    private final List<ComputerDetails> computers = new ArrayList<>();
    private final Listener listener;

    public ComputerListAdapter(Listener listener) {
        this.listener = listener;
        setHasStableIds(true);
    }

    /** Adds or replaces the computer with the same UUID. */
    public void upsert(ComputerDetails details) {
        if (details == null || details.uuid == null) {
            return;
        }
        for (int i = 0; i < computers.size(); i++) {
            if (details.uuid.equals(computers.get(i).uuid)) {
                computers.set(i, details);
                sortAndNotify();
                return;
            }
        }
        computers.add(details);
        sortAndNotify();
    }

    public void remove(String uuid) {
        for (int i = 0; i < computers.size(); i++) {
            if (computers.get(i).uuid.equals(uuid)) {
                computers.remove(i);
                notifyDataSetChanged();
                return;
            }
        }
    }

    public ComputerDetails find(String uuid) {
        for (ComputerDetails c : computers) {
            if (c.uuid.equals(uuid)) {
                return c;
            }
        }
        return null;
    }

    public int getComputerCount() {
        return computers.size();
    }

    private void sortAndNotify() {
        Collections.sort(computers, new Comparator<ComputerDetails>() {
            @Override
            public int compare(ComputerDetails a, ComputerDetails b) {
                int ra = rank(a), rb = rank(b);
                if (ra != rb) {
                    return Integer.compare(ra, rb);
                }
                String na = a.name == null ? "" : a.name;
                String nb = b.name == null ? "" : b.name;
                return na.compareToIgnoreCase(nb);
            }

            private int rank(ComputerDetails c) {
                return c.state == ComputerDetails.State.ONLINE ? 0 : 1;
            }
        });
        notifyDataSetChanged();
    }

    @Override
    public int getItemCount() {
        return computers.isEmpty() ? 0 : computers.size() + 1;
    }

    @Override
    public int getItemViewType(int position) {
        return position == 0 ? TYPE_HEADER : TYPE_COMPUTER;
    }

    @Override
    public long getItemId(int position) {
        if (position == 0) {
            return Long.MIN_VALUE;
        }
        return computers.get(position - 1).uuid.hashCode();
    }

    @NonNull
    @Override
    public RecyclerView.ViewHolder onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
        LayoutInflater inflater = LayoutInflater.from(parent.getContext());
        if (viewType == TYPE_HEADER) {
            return new RecyclerView.ViewHolder(inflater.inflate(R.layout.item_computer_header, parent, false)) {};
        }
        return new ComputerHolder(inflater.inflate(R.layout.item_computer, parent, false));
    }

    @Override
    public void onBindViewHolder(@NonNull RecyclerView.ViewHolder holder, int position) {
        if (holder instanceof ComputerHolder) {
            ((ComputerHolder) holder).bind(computers.get(position - 1));
        }
    }

    private class ComputerHolder extends RecyclerView.ViewHolder {
        private final ImageView icon;
        private final ImageView statusDot;
        private final TextView name;
        private final TextView status;
        private final TextView address;
        private final ImageButton menu;

        ComputerHolder(View itemView) {
            super(itemView);
            icon = itemView.findViewById(R.id.computerIcon);
            statusDot = itemView.findViewById(R.id.statusDot);
            name = itemView.findViewById(R.id.computerName);
            status = itemView.findViewById(R.id.computerStatus);
            address = itemView.findViewById(R.id.computerAddress);
            menu = itemView.findViewById(R.id.computerMenu);
        }

        void bind(final ComputerDetails computer) {
            Context context = itemView.getContext();

            name.setText(computer.name);

            int statusRes;
            int dotColor;
            boolean online = computer.state == ComputerDetails.State.ONLINE;
            if (computer.state == ComputerDetails.State.UNKNOWN) {
                statusRes = R.string.hermes_status_checking;
                dotColor = COLOR_OFFLINE;
            } else if (!online) {
                statusRes = R.string.hermes_status_offline;
                dotColor = COLOR_OFFLINE;
            } else if (computer.pairState != PairingManager.PairState.PAIRED) {
                statusRes = R.string.hermes_status_unpaired;
                dotColor = COLOR_ATTENTION;
            } else if (computer.runningGameId != 0) {
                statusRes = R.string.hermes_status_in_use;
                dotColor = COLOR_ONLINE;
            } else {
                statusRes = R.string.hermes_status_online;
                dotColor = COLOR_ONLINE;
            }
            status.setText(statusRes);
            statusDot.setImageTintList(ColorStateList.valueOf(dotColor));
            icon.setAlpha(online ? 1f : 0.45f);
            name.setAlpha(online ? 1f : 0.7f);

            ComputerDetails.AddressTuple addr = computer.activeAddress != null ? computer.activeAddress
                    : computer.manualAddress != null ? computer.manualAddress
                    : computer.localAddress != null ? computer.localAddress
                    : computer.remoteAddress;
            if (addr != null && addr.address != null) {
                address.setVisibility(View.VISIBLE);
                address.setText(addr.address);
            } else {
                address.setVisibility(View.GONE);
            }

            itemView.setOnClickListener(v -> listener.onComputerClicked(computer));
            itemView.setOnLongClickListener(v -> {
                listener.onComputerMenu(computer, menu);
                return true;
            });
            menu.setContentDescription(context.getString(R.string.hermes_more_options, computer.name));
            menu.setOnClickListener(v -> listener.onComputerMenu(computer, v));
        }
    }
}
