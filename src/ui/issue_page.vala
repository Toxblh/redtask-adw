namespace Redmine {
    public class IssuePage : Adw.NavigationPage {
        public int issue_id;
        public IssuePage (int id, int note) { Object (title: "#%d".printf (id)); issue_id = id; child = new Adw.ToolbarView () { content = new Gtk.Label ("#%d".printf (id)) }; ((Adw.ToolbarView) child).add_top_bar (new Adw.HeaderBar ()); }
        public void reveal_note (int note) {}
        public void refresh () {}
    }
}
