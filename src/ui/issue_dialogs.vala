namespace Redmine {
    public class IssueEditDialog : Adw.Dialog {
        public signal void created (Issue issue);
        public IssueEditDialog.create (int project_id, int parent_id) {}
    }
}
