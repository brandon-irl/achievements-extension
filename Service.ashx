<%@ WebHandler Language="C#" Class="Service" %>

using System;
using System.Text;
using System.IO;
using System.Web;
using System.Linq;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Xml;
using System.Xml.Linq;
using System.Xml.Serialization;
using ScreenConnect;

public class Service : WebServiceBase
{
	AchievementsProvider achievementsProvider;
	const string validationKey = "wXJSJ95g4Q2CZChNCW98";

	public Service()
	{
		achievementsProvider = new XmlAchievementsProvider();
	}

	public object GetAchievementDefinitions()
	{
		return achievementsProvider.GetAllDefinitions();
	}

	public object GetUsers()
	{
		return achievementsProvider.GetAllUsers();
	}

	public async Task<object> GetAchievementDataForLoggedOnUserAsync(long version)
	{
		var newVersion = await WaitForChangeManager.WaitForChangeAsync(version, null);
		return new
		{
			Version = newVersion,
			Achievements = GetAchievementDataForLoggedOnUser() //TODO: figure out why this causes some calls to throw a null ref exception: \u003e (Inner Exception #0) System.NullReferenceException: Object reference not set to an instance of an object.\r\n   at ScreenConnect.ExtensionContext.get_Current() in C:\\compile\\ScreenConnect\\ScreenConnectWork\\cwcontrol\\Product\\Server\\Extension.cs:line 727\r\n   at Service.XmlProviderBase.TryReadObjectXml[TObject](Func`2 additionalValidator) in c:\\compile\\ScreenConnect\\ScreenConnectWork\\cwcontrol\\Product\\Site\\App_Extensions\\90d13a55-d971-4a00-8d9b-e6edb7262b2f\\Service.ashx:line 207\r\n   at Service.AchievementsProvider.GetUser(String username) in c:\\compile\\ScreenConnect\\ScreenConnectWork\\cwcontrol\\Product\\Site\\App_Extensions\\90d13a55-d971-4a00-8d9b-e6edb7262b2f\\Service.ashx:line 101\r\n   at Service.\u003cGetAchievementDataForLoggedOnUserAsync\u003ed__1.MoveNext() in c:\\compile\\ScreenConnect\\ScreenConnectWork\\cwcontrol\\Product\\Site\\App_Extensions\\90d13a55-d971-4a00-8d9b-e6edb7262b2f\\Service.ashx:line 53\u003c---\r\n
		};
	}

	public object GetAchievementDataForLoggedOnUser()
	{
		return GetAchievementDataForUser(HttpContext.Current.User.Identity.Name);
	}

	public object GetAchievementDataForUser(string username)
	{
		username.AssertArgumentNonNull();

		return achievementsProvider.GetUserAchievements(username);
	}

	public object GetAchievementProgressForUser(string achievementTitle, string username)
	{
		achievementTitle.AssertArgumentNonNull();
		username.AssertArgumentNonNull();

		return achievementsProvider
				.GetUserAchievements(username)
				.Where(_ => _.Title == achievementTitle)
				.FirstOrDefault()
				.SafeNav(_ => _.Progress);
	}

	public void UpdateAchievementForLoggedOnUser(string key, string achievementTitle, string progress)
	{
		UpdateAchievementForUser(key, achievementTitle, progress, HttpContext.Current.User.Identity.Name);
	}

	public void UpdateAchievementForUser(string key, string achievementTitle, string progress, string username)
	{
		VerifyKey(key);

		if (string.IsNullOrWhiteSpace(username))
			throw new ArgumentNullException("username");

		achievementsProvider.UpdateUserAchievement(
			new UserAchievement { Title = achievementTitle, Progress = progress },
			username
		);
	}

	private void VerifyKey(string key)
	{
		if (key != validationKey)
			throw new HttpException(403, "Not allowed to set achievements yourself");
	}

	//	*****************************************Helper Stuff*****************************************
	public abstract class AchievementsProvider
	{
		public abstract User[] GetAllUsers();
		public abstract Definition[] GetAllDefinitions();
		public abstract UserAchievement[] GetUserAchievements(string username);
		public abstract void UpdateUserAchievement(UserAchievement achievement, string username);
	}

	public class XmlAchievementsProvider : AchievementsProvider
	{
		static FileInfo GetAchievementsFile()
		{
			var path = ExtensionContext.Current.BasePath + @"\" + "Achievements.xml";
			return new FileInfo(path);
		}

		static Achievements TryLoadAchievements()
		{
			return ServerExtensions.DeserializeXml<Achievements>(GetAchievementsFile().FullName);
		}

		static void ModifyAchievementsXml(Proc<Achievements> proc)
		{
			var achievements = TryLoadAchievements() ?? new Achievements();
			proc(achievements);
			ServerExtensions.SafeSerializeXml(XmlAchievementsProvider.GetAchievementsFile().FullName, achievements);
		}

		Definition GetDefinition(string definitionTitle)
		{
			return TryLoadAchievements()
					.DefinitionCollection.Definitions
					.Where(_ => _.Title == definitionTitle)
					.FirstOrDefault();
		}

		public override Definition[] GetAllDefinitions()
		{
			return TryLoadAchievements()
					.SafeNav(_ => _.DefinitionCollection.Definitions)
					.ToArray();
		}

		public override User[] GetAllUsers()
		{
			return TryLoadAchievements()
					.SafeNav(_ => _.UserCollection.Users)
					.ToArray();
		}

		public User GetUser(string username)
		{
			var user = TryLoadAchievements()
					.UserCollection.Users
					.Where(_ => _.Name == username)
					.FirstOrDefault();

			if (user == null)
				user = EnsureUserExistsInXml(username);

			return user;
		}

		public override UserAchievement[] GetUserAchievements(string username)
		{
			return TryLoadAchievements()
					.UserCollection.Users
					.Where(_ => _.Name == username)
					.FirstOrDefault()
					.UserAchievements
					.ToArray();
		}

		public override void UpdateUserAchievement(UserAchievement achievement, string username)
		{
			CheckAchievementProgressAgainstDefinition(achievement);
			ModifyAchievementsXml((_ =>
			{
				var user = _.UserCollection.Users
					.Where(__ => __.Name == username)
					.FirstOrDefault();
				var existingAchievement = user
					.UserAchievements
					.Where(__ => __.Title == achievement.Title)
					.FirstOrDefault();
				if (existingAchievement != null)
					existingAchievement = achievement;
				else
					user.UserAchievements.Add(achievement);
			}));
		}

		private void CheckAchievementProgressAgainstDefinition(UserAchievement achievement)
		{
			var definition = GetDefinition(achievement.Title);
			if (definition == null)
				throw new ArgumentException(string.Format("Achievement '{0}' does not exist", achievement.Title));

			achievement.Achieved = achievement.Progress == definition.Goal;     //TODO: this isn't really going to work the way we want it to for most achievements. Need a way to tell this method what operator to use
		}

		private User EnsureUserExistsInXml(string username)
		{
			username.AssertArgumentNonNull();

			var user = new User { Name = username };
			ModifyAchievementsXml((_ => _.UserCollection.Users.Add(user)));
			return GetUser(username);
		}
	}

	[SerializableAttribute()]
	[XmlTypeAttribute(AnonymousType = true)]
	[XmlRootAttribute(Namespace = "", IsNullable = false)]
	public partial class Achievements
	{
		[XmlElementAttribute("Definitions", typeof(DefinitionCollection), Form = System.Xml.Schema.XmlSchemaForm.Unqualified)]
		public DefinitionCollection DefinitionCollection;
		[XmlElementAttribute("Users", typeof(UserCollection), Form = System.Xml.Schema.XmlSchemaForm.Unqualified)]
		public UserCollection UserCollection;
	}

	[XmlTypeAttribute(AnonymousType = true)]
	public class Definition
	{
		[XmlAttributeAttribute()]
		public string Title;
		[XmlAttributeAttribute()]
		public string Description;
		[XmlAttributeAttribute()]
		public string Goal;
		[XmlAttributeAttribute()]
		public string Image = @"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";
		[XmlAttributeAttribute()]
		public bool HiddenUntilAchieved;
	}

	[System.SerializableAttribute()]
	[XmlTypeAttribute(AnonymousType = true)]
	public partial class DefinitionCollection
	{
		[XmlElementAttribute("Definition", Form = System.Xml.Schema.XmlSchemaForm.Unqualified)]
		public List<Definition> Definitions;
	}

	[System.SerializableAttribute()]
	[XmlTypeAttribute(AnonymousType = true)]
	public partial class UserCollection
	{
		[XmlElementAttribute("User", Form = System.Xml.Schema.XmlSchemaForm.Unqualified)]
		public List<User> Users;
	}

	[System.SerializableAttribute()]
	[XmlTypeAttribute(AnonymousType = true)]
	public class User
	{
		[XmlAttributeAttribute()]
		public string Name;
		[XmlElementAttribute("UserAchievement", Form = System.Xml.Schema.XmlSchemaForm.Unqualified)]
		public List<UserAchievement> UserAchievements;
	}

	[System.SerializableAttribute()]
	[XmlTypeAttribute(AnonymousType = true)]
	public class UserAchievement
	{
		[XmlAttributeAttribute()]
		public string Title;
		[XmlAttributeAttribute()]
		public string Progress;
		[XmlAttributeAttribute()]
		public bool Achieved;
	}
}