fn main() {
    let mut t = tera::Tera::new();
    t.load_from_glob("freeq-webui/templates/**/*").unwrap();
    println!("names: {:?}", t.get_template_names().collect::<Vec<_>>());
    let r = t.render("chat.html.tera", &tera::Context::new());
    println!("render result: {:?}", r.as_ref().map(|s| s.len()));
    if let Err(e) = r { println!("error: {e}"); }
}
