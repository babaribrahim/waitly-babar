// Shared localStorage helper: which rooms THIS browser has created (the
// only approximation of "your rooms" available without a real login
// system — see CLAUDE.md's admin-key-hash auth rationale). Each entry
// keeps the admin key returned once at creation time; losing it means
// losing management access to that room, same as the real API's model.
const WaitlyRooms = {
  KEY: "waitly-my-rooms",

  list() {
    try {
      return JSON.parse(localStorage.getItem(this.KEY) || "[]");
    } catch {
      return [];
    }
  },

  add(room) {
    const rooms = this.list();
    rooms.unshift(room);
    localStorage.setItem(this.KEY, JSON.stringify(rooms));
  },

  find(roomId) {
    return this.list().find((r) => r.roomId === roomId) || null;
  },
};
